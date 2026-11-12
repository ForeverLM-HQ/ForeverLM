import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit
import Darwin

private struct PreparedVideoPlaylistItem: Sendable {
    let item: YouTubePlaylistItem
    let sortIndex: Int
    let sourceTitle: String
    let identityKey: String
}

extension StudioViewModel {

    /// Import all videos from a YouTube playlist as a lecture series.
    /// If `intoCourse` is provided, lectures are added to that existing course.
    /// Otherwise, a new course group is created with the playlist title.
    /// Returns the course's stable ID when at least one lecture holds a video,
    /// and nil when nothing was attached (`errorMessage` then says why) — the
    /// `import_youtube_playlist` tool reports the course from it.
    @discardableResult
    func importYouTubePlaylist(url: String, intoCourse: String? = nil) async -> String? {
        urlInput = ""

        // Show feedback the instant the import starts. fetchPlaylist + the AI
        // title cleanup + the per-lecture insert can all run before the course
        // first appears, so without this the user stares at nothing for ~a
        // minute. `defer` guarantees the banner clears on every exit path.
        // A hide applies to the import it was pressed during, not to this one.
        playlistImportBannerHidden = false
        playlistImportStatus = intoCourse == nil ? "Adding course…" : "Adding lectures…"
        defer { playlistImportStatus = nil }

        do {
            let (playlistTitle, rawItems) = try await YouTubePlaylistService.shared.fetchPlaylist(from: url)
            let courseName = intoCourse ?? UUID().uuidString
            // The row spins from the moment the course has a name until the
            // import leaves this block, however it leaves it.
            importingCourseNames.insert(courseName)
            defer { importingCourseNames.remove(courseName) }
            let replacesPendingWebImport = intoCourse.flatMap {
                courseMetadata[$0]?.pendingPlaylistImport
            } == true
            let courseTitle = replacesPendingWebImport
                ? playlistTitle
                : (intoCourse.map(courseDisplayName) ?? playlistTitle)
            playlistImportStatus = "Importing “\(courseTitle)”…"
            let items = rawItems
            let aiLectureTitles = await cleanPlaylistLectureTitles(items, courseName: courseTitle)
            let cleanedLectureTitles = Self.uniquePlaylistLectureTitles(
                items,
                aiTitles: aiLectureTitles,
                courseName: courseTitle
            )
            let sourceTitles = Self.uniquePlaylistSourceTitles(
                items,
                lectureTitles: cleanedLectureTitles,
                courseName: courseTitle
            )
            let importedLectureNumbers = items.enumerated().compactMap { _, item in
                Self.materialOrdinal(in: cleanedLectureTitles[item.videoId] ?? item.title)?.major
            }
            if replacesPendingWebImport {
                var metadata = courseMetadata[courseName] ?? CourseMetadata()
                metadata.title = courseTitle
                metadata.playlistURL = url
                courseMetadata[courseName] = metadata
            }
            await persistCoursePlaylist(url, for: courseName, defaultTitle: courseTitle)
            await removeEmptyPlaceholderLectureIfNeeded(in: courseName, importedLectureNumbers: importedLectureNumbers)

            // Only the lectures this import adds are named from their content
            // below; the course's others keep the titles they have.
            let lectureIDsBefore = Set(courseLectures(for: courseName).map(\.id))
            let tally = await attachPlaylistItems(
                items,
                to: courseName,
                courseTitle: courseTitle,
                cleanedLectureTitles: cleanedLectureTitles,
                sourceTitles: sourceTitles
            )
            let added = tally.added

            if added > 0 {
                await normalizePlaylistLectureOrder(tally.lectureIdsInOrder, in: courseName)
                // Ensure the course name is tracked
                userCourseNames.insert(courseName)
                saveUserCourseNames()
                await refreshArticles()
                // Open the course's page to show the imported series.
                openCourse(courseName)
                if let firstLecture = courseLectures(for: courseName).first,
                   let firstItem = courseLectureItems(for: firstLecture.id).first,
                   let firstId = firstItem.sourceId {
                    selectedArticleId = firstId
                } else if let firstId = sourceIdsForGroup(courseName).sorted().first {
                    selectedArticleId = firstId
                }
                logger.info("Imported \(tally.added) lectures from playlist '\(playlistTitle)' into course '\(courseTitle)'")

                // Fill course metadata (subject title, code, institution,
                // instructors) from what the playlist itself says. New courses
                // only — an existing course's metadata is the learner's.
                if intoCourse == nil {
                    await applyExtractedCourseMetadata(
                        courseName: courseName,
                        playlistTitle: playlistTitle,
                        items: items
                    )
                }

                // Auto-fetch transcripts for all new lectures
                let courseSourceIds = Set(courseLectures(for: courseName)
                    .flatMap { courseLectureItems(for: $0.id) }
                    .compactMap(\.sourceId))
                let lectureIds = articles
                    .filter { courseSourceIds.contains($0.id) && $0.sourceType == .video && $0.content == nil }
                    .map(\.id)
                // The course is visible now, but its lectures have no transcripts
                // yet — keep the banner up so the ongoing work is explained.
                if !lectureIds.isEmpty {
                    playlistImportStatus = "Fetching lecture transcripts…"
                }
                await fetchYouTubeTranscriptsConcurrently(for: lectureIds)

                // Auto-match lectures to notes via LLM
                await matchLecturesToNotes(inCourse: courseName)

                // Name each new lecture for what it teaches now that its
                // transcript is in; a video title that already says so stays
                // (docs/courses-design.md, Lecture titles).
                let addedLectureIDs = Set(tally.lectureIdsInOrder).subtracting(lectureIDsBefore)
                if !addedLectureIDs.isEmpty {
                    playlistImportStatus = "Naming lectures…"
                    await retitleCourseLectures(courseID: courseName, lectureIDs: addedLectureIDs, reportsResult: false)
                }

                if replacesPendingWebImport {
                    var metadata = courseMetadata[courseName] ?? CourseMetadata()
                    metadata.title = courseTitle
                    metadata.playlistURL = url
                    metadata.pendingPlaylistImport = false
                    try await storage.saveCourseGroup(name: courseName, metadata: metadata)
                    courseMetadata[courseName] = metadata
                }

                // A completed import is a user-visible durability boundary. Push
                // the final course outline and source snapshots now so quitting
                // immediately after the banner disappears cannot strand them in
                // the local pending queue.
                playlistImportStatus = "Saving course to iCloud…"
                let unsyncedCount = await storage.syncCloudKitNowAndWaitForDrain()
                if unsyncedCount > 0 {
                    errorMessage = "The course is saved on this Mac, but \(unsyncedCount) iCloud change\(unsyncedCount == 1 ? " is" : "s are") still waiting to sync. Keep ForeverLM open and online."
                }
                if !tally.failures.isEmpty {
                    errorMessage = Self.partialPlaylistImportMessage(
                        courseTitle: courseTitle,
                        added: added,
                        itemCount: items.count,
                        failures: tally.failures
                    )
                }
                return courseName
            } else {
                // Nothing was attached, so a course created for this import
                // would sit in the sidebar as an empty shell reading 0. The one
                // the learner already had (`intoCourse`) is theirs to keep.
                if intoCourse == nil {
                    await discardEmptyPlaylistCourse(courseName)
                }
                errorMessage = Self.emptyPlaylistImportMessage(
                    courseTitle: courseTitle,
                    itemCount: items.count,
                    failures: tally.failures
                )
                return nil
            }
        } catch {
            errorMessage = "Failed to import playlist: \(error.localizedDescription)"
            logger.warning("Playlist import failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// What attaching a playlist's videos to a course came to.
    struct PlaylistImportTally: Equatable {
        /// Lectures that now hold a video: freshly inserted, revived, or already present.
        var added = 0
        /// Videos the learner had removed or archived before and asked for again.
        var revived = 0
        /// One description per video that could not be stored, in playlist order.
        var failures: [String] = []
        var lectureIdsInOrder: [String] = []
    }

    /// Attach each playlist video to a lecture of `courseName`, creating the
    /// source when the library lacks it.
    ///
    /// A playlist import is the learner asking for exactly these videos, so a
    /// removal tombstone or an archived row left by an earlier import of the
    /// same course must not veto it: re-importing a course after removing it would find
    /// every video dismissed, `insertSourceIfNew` would refuse each one, and
    /// the learner would get an empty course plus "All videos from this
    /// playlist are already in your library." The dismissal is cleared (and synced) here the way a
    /// re-liked video clears its own, and a storage failure on one video is
    /// counted and reported instead of silently swallowed.
    func attachPlaylistItems(
        _ items: [YouTubePlaylistItem],
        to courseName: String,
        courseTitle: String,
        cleanedLectureTitles: [String: String],
        sourceTitles: [String: String]
    ) async -> PlaylistImportTally {
        var tally = PlaylistImportTally()
        var existingURLKeys = Set(articles.map { Self.sourceURLIdentityKey($0.url) })
        var usedPlaylistLectureIds = Set<String>()
        for (index, item) in items.enumerated() {
            let playlistPosition = max(1, item.playlistIndex ?? index + 1)
            let playlistSortIndex = playlistPosition - 1
            let itemURLKey = Self.sourceURLIdentityKey(item.url)
            let cleanedTitle = cleanedLectureTitles[item.videoId]
            let lectureTitle = cleanedTitle ?? item.title
            let sourceTitle = sourceTitles[item.videoId] ?? item.title
            do {
                let articleId: String?
                if let existingIndex = existingArticleIndex(matchingSourceURL: item.url) {
                    articleId = articles[existingIndex].id
                } else if existingURLKeys.contains(itemURLKey) {
                    articleId = nil
                } else {
                    var article = StudioArticle(
                        url: item.url,
                        title: sourceTitle,
                        sourceType: .video,
                        discoveryOrigin: .youtubePlaylist
                    )
                    article.artworkURL = article.youtubeThumbnailURL
                    if try await storage.insertSourceIfNew(&article) {
                        articles.insert(article, at: tally.added)
                        existingURLKeys.insert(itemURLKey)
                        articleId = article.id
                    } else {
                        var existing = await storage.sourceRecordByNormalizedURL(itemURLKey)
                        if existing == nil {
                            existing = await storage.sourceRecordByURL(item.url)
                        }
                        if existing?.status == .active {
                            await refreshArticles()
                            existingURLKeys = Set(articles.map { Self.sourceURLIdentityKey($0.url) })
                            articleId = existing.flatMap { existing in
                                articles.first(where: { $0.id == existing.id })?.id
                            }
                        } else if let revivedID = try await storage.unarchiveSourceMatchingURL(
                            item.url,
                            clearingDismissal: true
                        ) {
                            // Archived by an earlier removal of this course; the
                            // learner has asked for it again.
                            await refreshArticles()
                            existingURLKeys = Set(articles.map { Self.sourceURLIdentityKey($0.url) })
                            articleId = articles.contains(where: { $0.id == revivedID }) ? revivedID : nil
                            tally.revived += 1
                        } else if try await storage.insertSourceIfNew(&article) {
                            // Only the removal tombstone stood in the way, and the
                            // revive attempt above has cleared it.
                            articles.insert(article, at: tally.added)
                            existingURLKeys.insert(itemURLKey)
                            articleId = article.id
                            tally.revived += 1
                        } else {
                            articleId = nil
                        }
                    }
                }

                guard let articleId else { continue }

                if let articleIndex = articles.firstIndex(where: { $0.id == articleId }),
                   Self.shouldRepairCoursePlaylistStoredTitle(
                       currentTitle: articles[articleIndex].title,
                       originalTitle: item.title,
                       cleanedLectureTitle: cleanedTitle,
                       replacementTitle: sourceTitle,
                       courseName: courseTitle
                   ) {
                    var updatedArticle = articles[articleIndex]
                    updatedArticle.title = sourceTitle
                    try await storage.saveSource(updatedArticle)
                    articles[articleIndex] = updatedArticle
                }

                let existingArticle = articles.first { $0.id == articleId }
                let lecture = await playlistItemLecture(
                    in: courseName,
                    title: lectureTitle,
                    playlistPosition: playlistPosition,
                    existingArticle: existingArticle,
                    usedLectureIds: usedPlaylistLectureIds
                )
                if let lecture {
                    usedPlaylistLectureIds.insert(lecture.id)
                    tally.lectureIdsInOrder.append(lecture.id)
                    // A lecture that already has a title keeps it: a refresh
                    // of the playlist must not undo a title named from the
                    // lecture's content, or one the learner gave it.
                    if cleanedTitle != nil,
                       lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        await updateCourseLectureTitle(lecture.id, title: lectureTitle)
                    }
                    await moveArticle(articleId, toLecture: lecture.id, inCourse: courseName)
                    await updateLectureItemSortIndex(articleId: articleId, lectureId: lecture.id, sortIndex: playlistSortIndex)
                    tally.added += 1
                }
            } catch {
                logger.error("Playlist import could not add video \(item.videoId) to '\(courseTitle)': \(error.localizedDescription)")
                tally.failures.append(error.localizedDescription)
            }
        }
        return tally
    }

    /// Inserts a source unless one is already there; false when it was not
    /// inserted, a storage failure included (which is logged).
    private func insertSourceIfNewLogged(_ article: inout StudioArticle) async -> Bool {
        do {
            return try await storage.insertSourceIfNew(&article)
        } catch {
            logger.error("Inserting a playlist source failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove the course group a playlist import created for itself when no
    /// lecture could be attached to it.
    func discardEmptyPlaylistCourse(_ courseName: String) async {
        do {
            _ = try await storage.deleteCourseGroup(name: courseName)
        } catch {
            logger.error("Failed to discard empty playlist course '\(courseName)': \(error.localizedDescription)")
        }
        courseMetadata.removeValue(forKey: courseName)
        courseLecturesByCourse[courseName] = nil
        userCourseNames.remove(courseName)
        saveUserCourseNames()
    }

    /// The message for an import that attached nothing: the storage failure
    /// when there was one, otherwise the honest reason every video was skipped.
    nonisolated static func emptyPlaylistImportMessage(courseTitle: String, itemCount: Int, failures: [String]) -> String {
        if let first = failures.first {
            let videos = itemCount == 1 ? "the video" : "any of the \(itemCount) videos"
            return "Couldn’t add \(videos) from “\(courseTitle)”: \(first)"
        }
        return "All videos from this playlist are already in your library."
    }

    /// The message for an import that attached some videos but not all.
    nonisolated static func partialPlaylistImportMessage(courseTitle: String, added: Int, itemCount: Int, failures: [String]) -> String {
        let missing = failures.count
        let detail = failures.first.map { ": \($0)" } ?? "."
        return "Added \(added) of \(itemCount) videos to “\(courseTitle)”. \(missing) couldn’t be added\(detail)"
    }

    /// Whether a course's row should spin: its lectures are being imported on
    /// this Mac, or it is a shell Web Studio authored whose playlist this Mac
    /// has yet to expand. Either way the count it would show is not the truth.
    func isImportingCourse(_ courseName: String) -> Bool {
        Self.courseIsImporting(
            courseName,
            importing: importingCourseNames,
            pendingWebImport: courseMetadata[courseName]?.pendingPlaylistImport == true
        )
    }

    /// Pure, so the rule can be tested without a view model.
    nonisolated static func courseIsImporting(_ courseName: String, importing: Set<String>, pendingWebImport: Bool) -> Bool {
        importing.contains(courseName) || pendingWebImport
    }

    /// Expands browser-authored course shells after a CloudKit course event or
    /// the initial library load. The explicit marker makes this idempotent and
    /// distinguishes the request from a course the learner intentionally left
    /// empty. Failures leave the marker set for the next event-driven retry.
    func drainPendingWebCourseImports() async {
        let pending = courseMetadata
            .filter { $0.value.pendingPlaylistImport }
            .sorted { $0.key < $1.key }

        for (courseID, metadata) in pending {
            guard let playlistURL = metadata.playlistURL,
                  YouTubePlaylistService.isPlaylistURL(playlistURL),
                  pendingWebCourseImportsInFlight.insert(courseID).inserted else { continue }
            await importYouTubePlaylist(url: playlistURL, intoCourse: courseID)
            pendingWebCourseImportsInFlight.remove(courseID)
        }
    }

    /// Manually refresh a persisted Videos playlist and add any new videos.
    func refreshVideoPlaylist(groupName: String) async {
        guard let metadata = videoPlaylistMetadata[groupName] else { return }
        if metadata.connectorKind == YouTubeImportSource.likedVideos.connectorKind {
            await refreshLikedYouTubeVideos(silent: false)
            return
        }
        if metadata.connectorKind == YouTubeImportSource.foreverLMPlaylist.connectorKind {
            // The group belongs to the account whose playlist it mirrors.
            if let account = youtubeAccounts.first(where: {
                $0.choices.foreverLMPlaylistID.map(YouTubeService.playlistURL(forID:)) == metadata.playlistURL
            }) {
                _ = await followYouTubeForeverLMPlaylist(accountID: account.id, silent: false, enablesAutoImport: false)
            }
            return
        }
        await refreshYouTubeVideoPlaylist(url: metadata.playlistURL, groupID: groupName)
    }

    /// Import (or refresh) a YouTube video feed into a playlist group. Public
    /// playlists and channel uploads are fetched keylessly; pass `prefetched`
    /// for feeds that must be fetched another way (e.g. the private, authenticated
    /// Liked-videos feed), which skips the keyless scrape and reuses everything
    /// downstream — dedup, titles, sort order, transcript fetching.
    /// Pass `unarchivesExistingSources: true` for feeds that mirror an upstream
    /// list, where archiving is something this sync did (on unlike) rather than
    /// something the user chose — there, an item reappearing upstream must undo
    /// the archive. Manually added playlists leave archived rows alone.
    /// Removal chosen *in the app* is different: it leaves a timestamped
    /// dismissal, and a mirror item outranks that only when its own action is
    /// fresher — a re-like after the removal — never merely by still being in
    /// the feed.
    /// `allowsAutomaticTranscriptFormatting` is false for Liked-video imports
    /// until the learner explicitly accepts the potentially large AI cost.
    /// Captions are still fetched and stored in that mode; only the billed LLM
    /// formatting pass is skipped.
    func refreshYouTubeVideoPlaylist(
        url: String,
        groupID: String?,
        silent: Bool = false,
        assignsParentGroup: Bool = true,
        reparentsExistingSources: Bool = true,
        unarchivesExistingSources: Bool = false,
        allowsAutomaticTranscriptFormatting: Bool = true,
        prefetched: (title: String, items: [YouTubePlaylistItem])? = nil
    ) async {
        let id = groupID ?? videoPlaylistID(for: url)
        guard !refreshingVideoPlaylistIDs.contains(id) else { return }
        refreshingVideoPlaylistIDs.insert(id)
        defer { refreshingVideoPlaylistIDs.remove(id) }

        do {
            let playlistTitle: String
            let rawItems: [YouTubePlaylistItem]
            if let prefetched {
                (playlistTitle, rawItems) = prefetched
            } else {
                (playlistTitle, rawItems) = try await YouTubePlaylistService.shared.fetchPlaylist(from: url)
            }
            let items = rawItems
            await persistVideoPlaylist(id: id, title: playlistTitle, playlistURL: url)

            func refreshedParentGroup(existing article: StudioArticle?) -> String? {
                if assignsParentGroup {
                    // A followed channel takes its new uploads into its group
                    // but leaves a video already in the library where it was:
                    // a liked row stays a liked row, and the Liked feed's
                    // unlike-archive keeps working for it.
                    guard let article, !reparentsExistingSources else { return id }
                    return article.parentGroup
                }
                guard let groupName = article?.parentGroup else { return nil }
                return isInlineVideoPlaylistGroup(groupName) ? nil : groupName
            }

            var added = 0
            var revived = 0
            var touched = 0
            var withheldByRemoval = 0
            var transcriptFetchIds: [String] = []
            // Stage all changes on a local copy and publish once at the end.
            // Mutating the published `articles` per video re-sorts the sidebar
            // between every await, so a playlist sync visibly churned the whole
            // tab until the final reload settled it back.
            var working = articles
            // Build the URL-identity lookup once, off the main actor, and keep it
            // updated incrementally. Rebuilding it — or reloading and re-decoding
            // the whole library — per playlist item made a sync O(items × library)
            // and beachballed the app.
            var identityIndex = await Self.detachedSourceIdentityIndex(from: working)
            var reloadedFromStorage = false

            // Manual removal in the app records a timestamped dismissal. For a
            // mirror feed, an item that is merely *still* liked from before
            // that removal must stay out — otherwise every sync would undo the
            // removal while the like sits unchanged upstream. Only an item
            // whose like is newer than the dismissal (the user re-liked it
            // after removing) gets past this map and may revive the row below.
            let dismissalDates: [String: Date]
            if unarchivesExistingSources {
                let stored = (await loggedRead("dismissed source dates") { try await storage.loadDismissedSourceDates() }) ?? [:]
                dismissalDates = await Task.detached(priority: .userInitiated) {
                    Self.dismissalDatesByIdentityKey(stored)
                }.value
            } else {
                dismissalDates = [:]
            }

            func rememberIdentityKeys(of article: StudioArticle, at offset: Int) {
                let key = Self.sourceURLIdentityKey(article.url)
                if identityIndex[key] == nil { identityIndex[key] = offset }
                if let normalizedURL = article.normalizedURL, identityIndex[normalizedURL] == nil {
                    identityIndex[normalizedURL] = offset
                }
            }

            func updateExistingSource(
                at existingIndex: Int,
                channelTitle: String?,
                sourceTitle: String,
                playlistSortIndex: Int
            ) async -> String {
                var changed = false
                let refreshedGroup = refreshedParentGroup(existing: working[existingIndex])
                if working[existingIndex].parentGroup != refreshedGroup {
                    working[existingIndex].parentGroup = refreshedGroup
                    changed = true
                }
                // Inline Liked videos intentionally have no group_members row,
                // so a sort index cannot persist for them. Assigning it anyway
                // made every sync look changed and republished the entire feed.
                if refreshedGroup != nil,
                   working[existingIndex].courseSortIndex != playlistSortIndex {
                    working[existingIndex].courseSortIndex = playlistSortIndex
                    changed = true
                }
                if let channelTitle, working[existingIndex].domain != channelTitle {
                    working[existingIndex].domain = channelTitle
                    changed = true
                }
                let currentTitle = working[existingIndex].title
                let shouldReplaceTitle = await Task.detached(priority: .utility) {
                    Self.shouldReplaceVideoPlaylistStoredTitle(
                        currentTitle: currentTitle,
                        sourceTitle: sourceTitle,
                        playlistTitle: playlistTitle
                    )
                }.value
                if shouldReplaceTitle {
                    working[existingIndex].title = sourceTitle
                    changed = true
                }
                if changed {
                    do {
                        try await storage.saveSource(working[existingIndex])
                    } catch {
                        logger.error("saveSource failed: \(error.localizedDescription, privacy: .public)")
                    }
                    touched += 1
                }
                return working[existingIndex].id
            }

            let preparedItems = await Task.detached(priority: .utility) {
                items.enumerated().map { index, item in
                    let playlistPosition = max(1, item.playlistIndex ?? index + 1)
                    return PreparedVideoPlaylistItem(
                        item: item,
                        sortIndex: playlistPosition - 1,
                        sourceTitle: Self.playlistSourceDisplayTitle(
                            originalTitle: item.title,
                            cleanedLectureTitle: nil,
                            courseName: playlistTitle
                        ),
                        identityKey: Self.sourceURLIdentityKey(item.url)
                    )
                }
            }.value

            for prepared in preparedItems {
                let item = prepared.item
                let playlistSortIndex = prepared.sortIndex
                let sourceTitle = prepared.sourceTitle
                let itemKey = prepared.identityKey
                if let dismissedAt = dismissalDates[itemKey],
                   !Self.likedFeedEntryOutranksDismissal(likedAt: item.likedAt, dismissedAt: dismissedAt) {
                    withheldByRemoval += 1
                    continue
                }
                let articleId: String?
                if let existingIndex = identityIndex[itemKey] {
                    articleId = await updateExistingSource(
                        at: existingIndex,
                        channelTitle: item.channelTitle,
                        sourceTitle: sourceTitle,
                        playlistSortIndex: playlistSortIndex
                    )
                } else {
                    var article = StudioArticle(
                        url: item.url,
                        title: sourceTitle,
                        sourceType: .video,
                        discoveryOrigin: .youtubePlaylist,
                        parentGroup: refreshedParentGroup(existing: nil)
                    )
                    article.domain = item.channelTitle ?? playlistTitle
                    if article.parentGroup != nil {
                        article.courseSortIndex = playlistSortIndex
                    }
                    article.artworkURL = article.youtubeThumbnailURL
                    article.likedAt = item.likedAt
                    article.videoPublishedAt = item.videoPublishedAt
                    let inserted = await insertSourceIfNewLogged(&article)
                    if inserted {
                        // `working` is never published directly (refreshArticles()
                        // reloads at the end), so append instead of front-insert to
                        // keep previously recorded index offsets valid.
                        working.append(article)
                        rememberIdentityKeys(of: article, at: working.count - 1)
                        articleId = article.id
                        transcriptFetchIds.append(article.id)
                        added += 1
                        touched += 1
                    } else {
                        // Storage already has this URL even though the staged copy
                        // doesn't (the sync started from a stale snapshot). One
                        // reconcile covers every later conflict in this sync, so
                        // don't repeat the full-library reload per item.
                        if !reloadedFromStorage {
                            reloadedFromStorage = true
                            working = preservingLoadedContent(
                                in: (await loggedRead("library sources") { try await storage.loadLibrarySources().sources }) ?? working,
                                preservingFrom: working
                            )
                            identityIndex = await Self.detachedSourceIdentityIndex(from: working)
                        }
                        if let existingIndex = identityIndex[itemKey] {
                            articleId = await updateExistingSource(
                                at: existingIndex,
                                channelTitle: nil,
                                sourceTitle: sourceTitle,
                                playlistSortIndex: playlistSortIndex
                            )
                        } else if unarchivesExistingSources {
                            // The dismissal gate above already let this item
                            // through, so any tombstone on its URL is outranked
                            // by a fresher like and must be cleared, not
                            // skipped around: dismissal blocks the revive here
                            // *and* the insert above, and it would re-archive
                            // the row on the next inbound sync. Leaving it
                            // once made a re-liked video vanish silently no
                            // matter how often it was liked again.
                            let revivedID = await loggedLookup("an archived source to revive") {
                                try await storage.unarchiveSourceMatchingURL(item.url, clearingDismissal: true)
                            }
                            if let revivedID {
                                // Missing from the active library but present as an
                                // archived row: this sync archived it when the video
                                // left the feed, and it is back now. The revived row
                                // lands in `articles` through the closing
                                // refreshArticles(), so it is deliberately not spliced
                                // into `working` — doing that per item is what made
                                // this loop O(items × library) before.
                                articleId = revivedID
                                transcriptFetchIds.append(revivedID)
                                revived += 1
                                touched += 1
                            } else if await insertSourceIfNewLogged(&article) {
                                // Nothing to revive, so the dismissal was the only
                                // thing that failed the insert above. It is gone
                                // now: bring the video back in this pass rather than
                                // leaving the user to wonder why the like did nothing
                                // until some later sync.
                                working.append(article)
                                rememberIdentityKeys(of: article, at: working.count - 1)
                                articleId = article.id
                                transcriptFetchIds.append(article.id)
                                added += 1
                                touched += 1
                            } else {
                                articleId = nil
                            }
                        } else {
                            articleId = nil
                        }
                    }
                }

                if let articleId {
                    do {
                        _ = try await storage.updateCourseSortIndex(articleId, playlistSortIndex)
                    } catch {
                        logger.error("updateCourseSortIndex failed: \(error.localizedDescription, privacy: .public)")
                    }
                    // Runs for existing rows too, which is what backfills the
                    // feed dates for videos imported before these columns
                    // existed — no separate migration or backfill job.
                    do {
                        _ = try await storage.updateVideoFeedDates(
                            articleId,
                            likedAt: item.likedAt,
                            videoPublishedAt: item.videoPublishedAt
                        )
                    } catch {
                        logger.error("updateVideoFeedDates failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            if touched > 0 {
                await refreshArticles()
                if !silent {
                    sidebarTab = .videos
                    if selectedArticleId == nil || groupID == nil {
                        selectedArticleId = sourceIDsForGroupInOrder(id).first
                    }
                }
                // Publish metadata first, then let transcript fetching and AI
                // formatting continue independently under the sidebar's
                // Processing section. Silent plugin refreshes follow the same
                // path so a newly liked video does not remain an idle placeholder.
                if !transcriptFetchIds.isEmpty {
                    let pendingIDs = transcriptFetchIds
                    let permitsFormatting = allowsAutomaticTranscriptFormatting
                    Task { [weak self] in
                        await self?.fetchYouTubeTranscriptsConcurrently(
                            for: pendingIDs,
                            allowsAutomaticFormatting: permitsFormatting
                        )
                    }
                }
                if !silent {
                    let appeared = added + revived
                    if appeared > 0 {
                        showToast("Added \(appeared) video\(appeared == 1 ? "" : "s") to \(videoPlaylistDisplayName(id))")
                    } else {
                        showToast("Playlist is already up to date")
                    }
                }
            } else if !silent {
                if withheldByRemoval > 0 {
                    // Every feed entry is a video the user removed in the app
                    // and hasn't re-liked since — nothing to do, not an error.
                    showToast("Playlist is already up to date")
                } else {
                    errorMessage = "No videos found in this playlist."
                }
            }
            logger.info(
                "Video feed sync finished: \(items.count) fetched, \(added) added, \(revived) revived, \(touched) changed, \(withheldByRemoval) withheld"
            )
        } catch {
            if !silent {
                errorMessage = "Failed to import playlist: \(error.localizedDescription)"
            }
            logger.warning("Video playlist import failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func sourceURLIdentityKey(_ url: String) -> String {
        URLNormalizer.normalize(url)
    }

    /// Whether a Liked-feed entry is fresh enough to override the user's manual
    /// removal of the same video. Removal records a timestamped dismissal; a
    /// like that predates it is stale intent — the video was liked, imported,
    /// and then deliberately removed — so it must not resurrect the row on
    /// every sync. Only a like placed after the removal (the user re-liked the
    /// video) wins. An entry with no liked date cannot prove freshness, so the
    /// dismissal stands.
    nonisolated static func likedFeedEntryOutranksDismissal(likedAt: Date?, dismissedAt: Date) -> Bool {
        guard let likedAt else { return false }
        return likedAt > dismissedAt
    }

    /// Collapse stored dismissal rows onto the URL-identity keys this sync
    /// matches feed items with. When several stored spellings normalize to one
    /// key, the latest removal wins.
    nonisolated static func dismissalDatesByIdentityKey(_ stored: [String: Date]) -> [String: Date] {
        var byKey: [String: Date] = [:]
        byKey.reserveCapacity(stored.count)
        for (url, dismissedAt) in stored {
            let key = sourceURLIdentityKey(url)
            byKey[key] = max(byKey[key] ?? .distantPast, dismissedAt)
        }
        return byKey
    }

    nonisolated static func sourceIdentityIndex(from articles: [StudioArticle]) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(articles.count * 2)

        for (offset, article) in articles.enumerated() {
            let key = Self.sourceURLIdentityKey(article.url)
            index[key] = index[key] ?? offset
            if let normalizedURL = article.normalizedURL {
                index[normalizedURL] = index[normalizedURL] ?? offset
            }
        }

        return index
    }

    /// Same as `sourceIdentityIndex(from:)`, but built off the main actor — the
    /// scan normalizes every stored URL, which is too much work for the main
    /// thread on large libraries.
    nonisolated static func detachedSourceIdentityIndex(from articles: [StudioArticle]) async -> [String: Int] {
        await Task.detached(priority: .userInitiated) {
            Self.sourceIdentityIndex(from: articles)
        }.value
    }

    func existingArticleIndex(matchingSourceURL url: String) -> Int? {
        let targetKey = Self.sourceURLIdentityKey(url)
        return Self.sourceIdentityIndex(from: articles)[targetKey]
    }

    /// Infer course metadata from an imported playlist via the `courseMetadata`
    /// AI task and fill only what the course doesn't have yet: the title is
    /// replaced only while it still equals the playlist-title default that
    /// `persistCoursePlaylist` set, and code/institution/instructors only when
    /// empty. Skips silently when no model is configured; a failure only logs —
    /// metadata enrichment must never fail an import.
    func applyExtractedCourseMetadata(
        courseName: String,
        playlistTitle: String,
        items: [YouTubePlaylistItem]
    ) async {
        guard let config = KeychainService.resolveConfig(for: .courseMetadata) else { return }

        let channelCounts = Dictionary(grouping: items.compactMap(\.channelTitle), by: { $0 })
        let dominantChannel = channelCounts.max { $0.value.count < $1.value.count }?.key

        do {
            let details = try await aiService.extractCourseMetadata(
                playlistTitle: playlistTitle,
                channelName: dominantChannel,
                lectureTitles: items.map(\.title),
                config: config
            )
            await updateCourseMetadata(groupName: courseName) { metadata in
                if let title = details.title,
                   metadata.title == nil || metadata.title == playlistTitle {
                    metadata.title = title
                }
                if metadata.courseCode?.isEmpty != false, let code = details.courseCode {
                    metadata.courseCode = code
                }
                if metadata.institution?.isEmpty != false, let institution = details.institution {
                    metadata.institution = institution
                }
                if metadata.instructors?.isEmpty != false, let instructors = details.instructors {
                    metadata.instructors = instructors
                }
            }
        } catch {
            logger.warning("Course metadata extraction failed for '\(playlistTitle)': \(error.localizedDescription)")
        }
    }

    func cleanPlaylistLectureTitles(
        _ items: [YouTubePlaylistItem],
        courseName: String
    ) async -> [String: String] {
        guard let config = KeychainService.resolveConfig(for: .articleMetadata) else {
            return [:]
        }

        do {
            let titles = try await aiService.cleanCourseLectureTitles(
                courseName: courseName,
                titles: items.enumerated().map { index, item in
                    (id: item.videoId, position: max(1, item.playlistIndex ?? index + 1), title: item.title)
                },
                config: config
            )
            return titles.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            logger.warning("Lecture title cleanup failed for '\(courseName)': \(error.localizedDescription)")
            return [:]
        }
    }

    static func cleanedPlaylistLectureTitle(
        originalTitle: String,
        aiTitle: String?,
        courseName _: String
    ) -> String? {
        guard let aiTitle else { return originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleanedAI = aiTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAI.isEmpty else { return originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
        // The configured batch metadata task reads the human-authored title and
        // owns its semantic cleanup. Re-parsing that output here accumulated a
        // second, conflicting title-cleaner. Batch uniquification below remains
        // deterministic and prevents any model mistake from collapsing sources.
        return cleanedAI
    }

    /// Finalize a playlist's lecture titles as a batch so cleanup can never
    /// collapse two videos into the same visible title. Explicit source parts
    /// are preserved by `cleanedPlaylistLectureTitle`; the video-position suffix
    /// is only a last resort for titles that remain equal after that cleanup.
    static func uniquePlaylistLectureTitles(
        _ items: [YouTubePlaylistItem],
        aiTitles: [String: String],
        courseName: String
    ) -> [String: String] {
        let finalized = items.map { item in
            let title = cleanedPlaylistLectureTitle(
                originalTitle: item.title,
                aiTitle: aiTitles[item.videoId],
                courseName: courseName
            ) ?? item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                id: item.videoId,
                position: item.playlistIndex,
                title: title
            )
        }
        return uniquifiedPlaylistTitles(finalized)
    }

    static func uniquePlaylistSourceTitles(
        _ items: [YouTubePlaylistItem],
        lectureTitles: [String: String],
        courseName: String
    ) -> [String: String] {
        let finalized = items.map { item in
            (
                id: item.videoId,
                position: item.playlistIndex,
                title: playlistSourceDisplayTitle(
                    originalTitle: item.title,
                    cleanedLectureTitle: lectureTitles[item.videoId],
                    courseName: courseName
                )
            )
        }
        return uniquifiedPlaylistTitles(finalized)
    }

    static func uniquifiedPlaylistTitles(
        _ titles: [(id: String, position: Int?, title: String)]
    ) -> [String: String] {
        let counts = Dictionary(grouping: titles, by: { playlistTitleUniquenessKey($0.title) })
            .mapValues(\.count)

        var result: [String: String] = [:]
        var usedKeys = Set<String>()
        for (index, entry) in titles.enumerated() {
            let baseKey = playlistTitleUniquenessKey(entry.title)
            var candidate = entry.title
            if counts[baseKey, default: 0] > 1 || usedKeys.contains(baseKey) {
                let position = max(1, entry.position ?? index + 1)
                candidate = "\(entry.title) · Video \(position)"
            }

            // Playlist video IDs are stable and unique. This branch should be
            // practically unreachable, but it keeps the uniqueness guarantee
            // intact even if a human-authored title already contains the exact
            // position suffix generated above.
            if usedKeys.contains(playlistTitleUniquenessKey(candidate)) {
                candidate += " · \(entry.id)"
            }

            usedKeys.insert(playlistTitleUniquenessKey(candidate))
            result[entry.id] = candidate
        }
        return result
    }

    static func playlistTitleUniquenessKey(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func playlistSourceDisplayTitle(
        originalTitle: String,
        cleanedLectureTitle: String?,
        courseName: String
    ) -> String {
        (cleanedLectureTitle ?? originalTitle).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldRepairCoursePlaylistStoredTitle(
        currentTitle: String,
        originalTitle: String,
        cleanedLectureTitle: String?,
        replacementTitle: String,
        courseName: String
    ) -> Bool {
        let currentKey = playlistTitleUniquenessKey(currentTitle)
        let replacementKey = playlistTitleUniquenessKey(replacementTitle)
        guard !replacementKey.isEmpty, currentKey != replacementKey else {
            return false
        }

        return false
    }

    static func videoPlaylistDisplayTitle(
        storedTitle: String,
        playlistTitle: String,
        sortIndex: Int?
    ) -> String {
        let title = playlistSourceDisplayTitle(
            originalTitle: storedTitle,
            cleanedLectureTitle: nil,
            courseName: playlistTitle
        )
        guard let sortIndex, sortIndex >= 0 else {
            return title
        }
        return numberedOutlineRowTitle(title, number: sortIndex + 1)
    }

    nonisolated static func shouldReplaceVideoPlaylistStoredTitle(
        currentTitle: String,
        sourceTitle: String,
        playlistTitle: String
    ) -> Bool {
        let current = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return false }
        if current.isEmpty { return true }

        let normalizedCurrent = normalizedCourseLabel(current)
        let normalizedReplacement = normalizedCourseLabel(replacement)
        guard normalizedCurrent != normalizedReplacement else { return false }

        return false
    }

    /// Use an LLM to match lecture videos to PDF notes within a course,
    /// then set `lectureGroupId` on both so the sidebar can sub-group them.
    func matchLecturesToNotes(inCourse courseName: String) async {
        let courseItems = courseArticles(for: courseName)
        let lectures = courseItems.filter { $0.sourceType == .video }
        let notes = courseItems.filter { $0.sourceType == .course }

        guard !lectures.isEmpty, !notes.isEmpty else {
            logger.info("Skipping lecture-note matching for '\(courseName)': need both lectures and notes")
            return
        }

        let deterministicMatchCount = await matchLecturesToNotesByOrdinal(inCourse: courseName, lectures: lectures, notes: notes)

        guard let config = KeychainService.resolveConfig(for: .lectureNoteMatching) else {
            if deterministicMatchCount == 0 {
                logger.info("Skipping AI lecture-note matching: no API key configured")
            }
            return
        }

        // Strip course prefix from titles for cleaner matching
        let prefix = "\(courseName) – "
        let lectureTitles = lectures.map { $0.title.hasPrefix(prefix) ? String($0.title.dropFirst(prefix.count)) : $0.title }
        let noteFilenames = notes.compactMap { article -> String in
            if let path = article.localFilePath ?? (article.url.hasPrefix("/") ? article.url : nil) {
                return (path as NSString).lastPathComponent
            }
            return article.title.hasPrefix(prefix) ? String(article.title.dropFirst(prefix.count)) : article.title
        }

        do {
            let matches = try await aiService.matchLecturesToNotes(
                lectureTitles: lectureTitles,
                noteFilenames: noteFilenames,
                config: config
            )

            var matchCount = 0
            for match in matches {
                // Find the lecture article by its stripped title
                guard let lectureMatch = lectures.first(where: {
                    ($0.title.hasPrefix(prefix) ? String($0.title.dropFirst(prefix.count)) : $0.title) == match.lecture
                }),
                      let lectureIdx = articles.firstIndex(where: { $0.id == lectureMatch.id }) else { continue }

                // Find the note article by its filename
                guard let noteMatch = notes.first(where: { article in
                    if let path = article.localFilePath ?? (article.url.hasPrefix("/") ? article.url : nil) {
                        return (path as NSString).lastPathComponent == match.note
                    }
                    let stripped = article.title.hasPrefix(prefix) ? String(article.title.dropFirst(prefix.count)) : article.title
                    return stripped == match.note
                }),
                      let noteIdx = articles.firstIndex(where: { $0.id == noteMatch.id }) else { continue }

                let groupId = articles[lectureIdx].id
                articles[lectureIdx].lectureGroupId = groupId
                articles[noteIdx].lectureGroupId = groupId
                if let lecture = courseLectures(for: courseName).first(where: { lecture in
                    courseLectureItems(for: lecture.id).contains { $0.sourceId == articles[lectureIdx].id }
                }) {
                    await addArticleToLecture(articleId: articles[noteIdx].id, lectureId: lecture.id)
                }
                matchCount += 1
            }

            if matchCount > 0 {
                let courseSourceIDs = sourceIdsForGroup(courseName)
                let matched = articles.filter { $0.lectureGroupId != nil && courseSourceIDs.contains($0.id) }
                do {
                    try await storage.saveSourcesBatchOnly(matched)
                } catch {
                    logger.error("saveSourcesBatchOnly failed: \(error.localizedDescription, privacy: .public)")
                }
                logger.info("Matched \(matchCount) lectures to notes in '\(courseName)'")
            }
        } catch {
            logger.warning("Lecture-note matching failed for '\(courseName)': \(error.localizedDescription)")
        }
    }

    /// Deterministically match materials named like "Chapter 7" or "Lecture 7"
    /// to the unique video lecture with the same number. This catches common
    /// course-note naming without requiring an AI configuration.
    @discardableResult
    func matchLecturesToNotesByOrdinal(
        inCourse courseName: String,
        lectures: [StudioArticle],
        notes: [StudioArticle]
    ) async -> Int {
        let videosByLessonMajor = Dictionary(grouping: lectures.compactMap { video -> (Int, StudioArticle)? in
            guard let ordinal = Self.materialOrdinal(for: video, courseName: courseName),
                  ordinal.kind == "lesson" else { return nil }
            return (ordinal.major, video)
        }, by: { $0.0 })
        guard !videosByLessonMajor.isEmpty else { return 0 }

        var matchedArticles: [StudioArticle] = []
        var matchCount = 0
        for note in notes {
            guard let ordinal = Self.materialOrdinal(for: note, courseName: courseName),
                  ordinal.kind == "lesson",
                  let videoMatches = videosByLessonMajor[ordinal.major],
                  videoMatches.count == 1,
                  let video = videoMatches.first?.1,
                  let videoLecture = courseLectures(for: courseName).first(where: { lecture in
                      courseLectureItems(for: lecture.id).contains { $0.sourceId == video.id }
                  }) else { continue }

            if let noteIndex = articles.firstIndex(where: { $0.id == note.id }) {
                articles[noteIndex].lectureGroupId = video.id
                matchedArticles.append(articles[noteIndex])
            }
            if let videoIndex = articles.firstIndex(where: { $0.id == video.id }) {
                articles[videoIndex].lectureGroupId = video.id
                matchedArticles.append(articles[videoIndex])
            }
            await moveArticle(note.id, toLecture: videoLecture.id, inCourse: courseName)
            matchCount += 1
        }

        if !matchedArticles.isEmpty {
            do {
                try await storage.saveSourcesBatchOnly(matchedArticles)
            } catch {
                logger.error("saveSourcesBatchOnly failed: \(error.localizedDescription, privacy: .public)")
            }
            logger.info("Matched \(matchCount) lectures to notes by number in '\(courseName)'")
        }
        return matchCount
    }
}
