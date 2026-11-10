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

    // MARK: - Course Collections

    /// All known course group names (user-created + auto-discovered) the
    /// open library shows: the learner's own courses, and the teams'
    /// (docs/teams-design.md, decision 21) — every team's in My Library, the
    /// open team's in a team library. A team's copy of an own course is that
    /// course seen once, as a Doc's copy is (decision 18).
    var allCourseGroupNames: [String] {
        // Touch every observable input before the cache: the cache is
        // observation-ignored, so a body served from it would subscribe to
        // nothing. A Courses home drawn after another reader filled the cache
        // during launch kept "No courses yet." once the courses had loaded.
        let metadata = courseMetadata
        let lectures = courseLecturesByCourse
        let teamIDs = courseTeamIDs
        let openTeamID = activeTeamID
        _ = courseOrder
        if let allCourseGroupNamesCache {
            return allCourseGroupNamesCache
        }
        var names = Set(metadata.keys)
        names.formUnion(lectures.keys)
        if !teamIDs.isEmpty {
            let own = names.filter { teamIDs[$0] == nil }
            var copiesOfOwn = Set<String>()
            for teamID in Set(teamIDs.values) {
                for courseID in own {
                    copiesOfOwn.insert(TeamContentIdentity.courseID(teamID: teamID, originalCourseID: courseID))
                }
            }
            names = names.filter { courseID in
                guard let teamID = teamIDs[courseID] else { return true }
                if let openTeamID, teamID != openTeamID { return false }
                return !copiesOfOwn.contains(courseID)
            }
        }
        let ordered = orderedCourseNames(Array(names))
        allCourseGroupNamesCache = ordered
        return ordered
    }

    /// The team a course is a copy in, or nil for the learner's own.
    func courseTeam(_ courseID: String) -> TeamRecord? {
        courseTeamIDs[courseID].flatMap { team(id: $0) }
    }

    /// Whether a course's page can be drawn in the library on screen: the
    /// learner's own course anywhere, a team's only in that team's library,
    /// the one that lists its rows.
    func courseOpensInActiveLibrary(_ courseID: String) -> Bool {
        guard let teamID = courseTeamIDs[courseID] else { return true }
        return teamID == activeTeamID
    }

    /// The Courses home's cards: every course not hidden, narrowed by what is
    /// typed in its search field (courses-design.md).
    func courseGroupNames(matching query: String) -> [String] {
        shownCourseGroupNames.filter { courseMatchesSearch($0, query: query) }
    }

    /// The courses a list may name: every course not hidden, and while Screen
    /// record mode is on only those the take may show
    /// (`screenRecordShownCourseIDs`, none until they are read). The courses in
    /// memory stay whole.
    var shownCourseGroupNames: [String] {
        let visible = visibleCourseGroupNames
        guard screenRecordScope != nil else { return visible }
        let shown = screenRecordShownCourseIDs ?? []
        return visible.filter(shown.contains)
    }

    /// Reads the courses Screen record mode lets on screen, off the main actor,
    /// after the scope changes and after the courses, their homes or the
    /// Notebooks reload. With the mode off there is nothing to read.
    func refreshScreenRecordShownCourses() {
        screenRecordShownCoursesTask?.cancel()
        guard screenRecordScope != nil else {
            if screenRecordShownCourseIDs != nil { screenRecordShownCourseIDs = nil }
            return
        }
        screenRecordShownCoursesTask = Task { [weak self] in
            await self?.loadScreenRecordShownCourses()
        }
    }

    func loadScreenRecordShownCourses() async {
        guard let scope = screenRecordScope else { return }
        // A read that fails shows no course: the mode's lists fail closed.
        let shown = (try? await storage.screenRecordShownCourseIDs(scope: scope)) ?? []
        guard !Task.isCancelled, screenRecordScope == scope, screenRecordShownCourseIDs != shown else { return }
        screenRecordShownCourseIDs = shown
    }

    var visibleCourseGroupNames: [String] {
        // Through `allCourseGroupNames` first, which subscribes the caller to
        // every input, `isHidden` included, on a cache hit too.
        let all = allCourseGroupNames
        if let visibleCourseGroupNamesCache {
            return visibleCourseGroupNamesCache
        }
        let visible = all.filter { !(courseMetadata[$0]?.isHidden ?? false) }
        visibleCourseGroupNamesCache = visible
        return visible
    }

    /// Courses the learner hid, less one whose removal is inside its Undo
    /// window — that course is being removed, not kept. See `isSourceBeingRemoved`.
    var hiddenCourseGroupNames: [String] {
        orderedCourseNames(allCourseGroupNames.filter {
            courseMetadata[$0]?.isHidden == true
                && !hasPendingDeletion(forDeletionKey: Self.courseRemovalKey($0))
        })
    }

    func orderedCourseNames(_ names: [String]) -> [String] {
        let available = Set(names)
        var included = Set<String>()
        var ordered = courseOrder.reduce(into: [String]()) { result, courseName in
            if available.contains(courseName), included.insert(courseName).inserted {
                result.append(courseName)
            }
        }
        let remainder = names
            .filter { !included.contains($0) }
        let displayNames = Dictionary(
            uniqueKeysWithValues: remainder.map { ($0, courseDisplayName($0)) }
        )
        ordered.append(contentsOf: remainder.sorted {
            (displayNames[$0] ?? $0).localizedStandardCompare(displayNames[$1] ?? $1) == .orderedAscending
        })
        return ordered
    }

    /// Move a course before another course on the Courses home.
    func reorderCourse(from source: String, to destination: String) {
        guard source != destination else { return }
        var ordered = allCourseGroupNames
        guard let fromIndex = ordered.firstIndex(of: source),
              let toIndex = ordered.firstIndex(of: destination) else { return }
        ordered.remove(at: fromIndex)
        ordered.insert(source, at: toIndex)
        courseOrder = ordered
    }

    /// Reset the custom course order to the display-title sort.
    func sortCoursesByTitle() {
        courseOrder = allCourseGroupNames.sorted {
            courseDisplayName($0).localizedStandardCompare(courseDisplayName($1)) == .orderedAscending
        }
    }

    func courseMatchesSearch(_ groupName: String, query rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed = SidebarSearchQuery(parsing: query)
        guard !parsed.isEmpty else { return true }
        let meta = courseMetadata[groupName]
        // Joined, so a query may run from the course code into the title the way
        // the row prints them; the folded pass inside handles hyphenation.
        let searchable = [
            groupName,
            courseDisplayName(groupName),
            meta?.courseCode,
            meta?.title,
            meta?.institution,
            meta?.instructors,
            meta?.playlistURL,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return Self.sidebarGroupMatchesSearch(
            parsed,
            metadata: [searchable],
            titles: [groupName, courseDisplayName(groupName), meta?.title].compactMap { $0 },
            authors: [meta?.instructors].compactMap { $0 }
        )
    }

    // MARK: - Video Playlist Collections

    var allVideoPlaylistGroupNames: [String] {
        orderedVideoPlaylistNames(Array(videoPlaylistMetadata.keys))
    }

    var visibleVideoPlaylistGroupNames: [String] {
        allVideoPlaylistGroupNames.filter {
            !(videoPlaylistMetadata[$0]?.isHidden ?? false)
                && !isInlineVideoPlaylistGroup($0)
        }
    }

    var inlineVideoPlaylistGroupNames: [String] {
        orderedVideoPlaylistNames(
            allVideoPlaylistGroupNames.filter {
                !(videoPlaylistMetadata[$0]?.isHidden ?? false)
                    && isInlineVideoPlaylistGroup($0)
            }
        )
    }

    func isInlineVideoPlaylistGroup(_ groupName: String) -> Bool {
        guard let kind = videoPlaylistMetadata[groupName]?.connectorKind else { return false }
        return kind == YouTubeImportSource.likedVideos.connectorKind
            || kind == YouTubeImportSource.foreverLMPlaylist.connectorKind
    }

    /// Whether a video renders as a flat row in the Videos tab rather than inside
    /// a collapsible playlist group: it belongs to no playlist, or to a visible
    /// inline playlist (Liked videos, the ForeverLM playlist). A video filed
    /// under a course rather than a playlist — a Teachable lecture — is a flat
    /// row too: course videos are listed here as well as on their course's page
    /// (courses-design.md). The sidebar lays rows out by this predicate and the
    /// view model pages by it, so the two never disagree about which rows exist.
    func isFlatVideoRow(_ article: StudioArticle) -> Bool {
        guard let groupName = article.parentGroup,
              let playlist = videoPlaylistMetadata[groupName] else { return true }
        return !playlist.isHidden && isInlineVideoPlaylistGroup(groupName)
    }

    var filteredVideoPlaylistGroupNames: [String] {
        visibleVideoPlaylistGroupNames.filter { groupName in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = SidebarSearchQuery(parsing: query)
            guard !parsed.isEmpty else { return true }
            let displayName = videoPlaylistDisplayName(groupName)
            if Self.sidebarGroupMatchesSearch(parsed, metadata: [displayName], titles: [displayName]) {
                return true
            }
            return activeArticles
                .filter { $0.parentGroup == groupName && $0.sourceType == .video }
                .contains { sourceMatchesSearch($0, query: query) }
        }
    }

    var hiddenVideoPlaylistGroupNames: [String] {
        orderedVideoPlaylistNames(allVideoPlaylistGroupNames.filter {
            videoPlaylistMetadata[$0]?.isHidden == true
                && !hasPendingDeletion(forDeletionKey: Self.videoPlaylistRemovalKey($0))
        })
    }

    func orderedVideoPlaylistNames(_ names: [String]) -> [String] {
        names.sorted { videoPlaylistDisplayName($0).localizedStandardCompare(videoPlaylistDisplayName($1)) == .orderedAscending }
    }

    func videoPlaylistDisplayName(_ groupName: String) -> String {
        videoPlaylistMetadata[groupName]?.title ?? groupName
    }

    /// The uploader channel stored in `domain` for a video row. Rows imported
    /// before channel capture may still hold noise there — the playlist title
    /// (e.g. "Liked videos"), the group header, or the URL host — so return it
    /// only when it reads as a real channel name that adds information.
    func videoChannelName(for article: StudioArticle) -> String? {
        guard article.sourceType == .video else { return nil }
        let domain = article.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return nil }
        if domain.localizedCaseInsensitiveCompare("Liked videos") == .orderedSame { return nil }
        if domain.localizedCaseInsensitiveCompare(YouTubeService.foreverLMPlaylistName) == .orderedSame { return nil }
        if let host = URL(string: article.url)?.host,
           domain.compare(host, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        if let group = article.parentGroup {
            if domain.localizedCaseInsensitiveCompare(group) == .orderedSame { return nil }
            if domain.localizedCaseInsensitiveCompare(videoPlaylistDisplayName(group)) == .orderedSame { return nil }
        }
        return domain
    }

    func videoPlaylistID(for playlistURL: String) -> String {
        "playlist_" + Self.sourceURLIdentityKey(playlistURL)
    }

    func persistVideoPlaylist(
        id: String,
        title: String,
        playlistURL: String,
        refreshedAt: Date = Date()
    ) async {
        var metadata = videoPlaylistMetadata[id] ?? VideoPlaylistMetadata(title: title, playlistURL: playlistURL)
        metadata.title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : metadata.title
        metadata.playlistURL = playlistURL
        metadata.lastRefreshedAt = refreshedAt
        videoPlaylistMetadata[id] = metadata
        do {
            try await storage.saveVideoPlaylistGroup(id: id, metadata: metadata)
        } catch {
            logger.error("Failed to persist video playlist '\(title)': \(error.localizedDescription)")
        }
    }

    func updateVideoPlaylistTitle(groupName: String, title: String) async {
        guard var metadata = videoPlaylistMetadata[groupName] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        metadata.title = trimmed
        videoPlaylistMetadata[groupName] = metadata
        do {
            try await storage.saveVideoPlaylistGroup(id: groupName, metadata: metadata)
        } catch {
            logger.error("Failed to rename video playlist: \(error.localizedDescription)")
        }
    }

    func setVideoPlaylistHidden(_ groupName: String, hidden: Bool) async {
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.videoPlaylistRemovalKey(groupName)) {
            guard videoPlaylistMetadata[groupName]?.isHidden == true else { return }
        }
        guard var metadata = videoPlaylistMetadata[groupName] else { return }
        metadata.isHidden = hidden
        videoPlaylistMetadata[groupName] = metadata
        do {
            try await storage.saveVideoPlaylistGroup(id: groupName, metadata: metadata)
            showToast(
                hidden ? "Hid \(metadata.title)" : "Unhid \(metadata.title)",
                undo: hidden ? { [weak self] in await self?.setVideoPlaylistHidden(groupName, hidden: false) } : nil
            )
        } catch {
            logger.error("Failed to update video playlist visibility: \(error.localizedDescription)")
        }
    }

    func removeVideoPlaylistGroup(_ groupName: String) async {
        guard !hasPendingDeletion(forDeletionKey: Self.videoPlaylistRemovalKey(groupName)) else { return }
        guard let originalMetadata = videoPlaylistMetadata[groupName] else { return }
        let title = videoPlaylistDisplayName(groupName)
        let sourceIDs = Set(activeArticles.filter {
            $0.parentGroup == groupName && $0.sourceType == .video
        }.map(\.id))
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds
        var hiddenMetadata = originalMetadata
        hiddenMetadata.isHidden = true

        do {
            try await storage.saveVideoPlaylistGroup(id: groupName, metadata: hiddenMetadata)
        } catch {
            logger.error("Failed to remove video playlist: \(error.localizedDescription)")
            showToast("Removing “\(title)” failed: \(error.localizedDescription)")
            return
        }
        videoPlaylistMetadata[groupName] = hiddenMetadata
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
            deletionKey: Self.videoPlaylistRemovalKey(groupName),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.saveVideoPlaylistGroup(id: groupName, metadata: originalMetadata)
                    self.videoPlaylistMetadata[groupName] = originalMetadata
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } catch {
                    self.logger.error("Failed to undo video playlist removal: \(error.localizedDescription)")
                    self.showToast("Undo failed for “\(title)”: \(error.localizedDescription)")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                do {
                    for id in sourceIDs {
                        try await self.storage.archiveSource(id)
                    }
                    try await self.storage.deleteVideoPlaylistGroup(id: groupName)
                } catch {
                    try? await self.storage.saveVideoPlaylistGroup(id: groupName, metadata: originalMetadata)
                    self.videoPlaylistMetadata[groupName] = originalMetadata
                    self.logger.error("Failed to finalize video playlist removal: \(error.localizedDescription)")
                    self.showToast("Removing “\(title)” failed: \(error.localizedDescription)")
                    return
                }
                self.videoPlaylistMetadata[groupName] = nil
                self.articles.removeAll { sourceIDs.contains($0.id) }
            }
        )
    }
}
