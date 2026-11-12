// The course playlist import and YouTube metadata tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

@Suite("Course Playlist Import")
@MainActor
struct CoursePlaylistImportTests {

    @Test("Lettered playlist ordinals collapse to the same lecture number")
    func letteredPlaylistOrdinalsUseMajorLectureNumber() {
        #expect(StudioViewModel.materialOrdinal(in: "5A) Temporal order, Global Structure, and Memory")?.major == 5)
        #expect(StudioViewModel.materialOrdinal(in: "5B) Temporal order, Global Structure, and Memory")?.major == 5)
        #expect(StudioViewModel.materialOrdinal(in: "Lecture 8B - Robustness using bifunctional components")?.major == 8)
    }

    @Test("A title with no lecture number has no ordinal, so the item order stands")
    func titlesWithoutALectureNumberHaveNoOrdinal() {
        #expect(StudioViewModel.materialOrdinal(in: "Feed Forward Loops") == nil)
    }

    @Test("Playlist lecture cleanup preserves original title when AI is unavailable")
    func playlistLectureCleanupPreservesOriginalWithoutAI() {
        let title = "Lecture 3: Age - Related Diseases, 17.11.2025 - Systems Aging and Longevity, Autumn 2025"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: nil, courseName: "Systems Aging") == title)
    }

    @Test("Playlist lecture cleanup does not re-parse the configured LLM's result")
    func playlistLectureCleanupTrustsConfiguredLLM() {
        let title = "Lecture 12: Friends, Stress and Wisdom, 19.1.2026 - Systems Aging and Longevity, Autumn 2025"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "1) Friends, Stress and Wisdom", courseName: "Systems Aging") == "1) Friends, Stress and Wisdom")
    }

    @Test("Playlist lecture cleanup trusts LLM title text")
    func playlistLectureCleanupTrustsLLMTitleText() {
        let title = "Lecture 4: Epigenetic Clocks - Systems Aging"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "4) Epigenetic Clocks | YouTube", courseName: "Systems Aging") == "4) Epigenetic Clocks | YouTube")
    }

    @Test("Playlist lecture cleanup preserves slash-separated original titles")
    func playlistLectureCleanupPreservesSlashSeparatedOriginalTitles() {
        let title = "7.05 Biochemistry / 12. /Introduction to Membranes"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: nil, courseName: "Biochemistry") == title)
    }

    @Test("Playlist lecture cleanup trusts separators in AI titles")
    func playlistLectureCleanupTrustsSeparatorsInAITitles() {
        let title = "7.05 Biochemistry / 12. Introduction to Membranes"
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "12) /Introduction to Membranes", courseName: "Biochemistry") == "12) /Introduction to Membranes")
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(originalTitle: title, aiTitle: "12) Biochemistry / Introduction to Membranes", courseName: "Biochemistry") == "12) Biochemistry / Introduction to Membranes")
    }

    @Test("Playlist lecture cleanup preserves the batch LLM output verbatim")
    func playlistLectureCleanupPreservesBatchLLMOutput() {
        let cases = [
            ("Lecture 3 Part a - Feed Forward Loops", "3) Feed Forward Loops", "3) Feed Forward Loops"),
            ("Lecture 3 - Part b - Feed Forward Loop", "3) Feed Forward Loop", "3) Feed Forward Loop"),
            ("Lecture 4 a - Temporal order, Global Structure, and Memory", "4) Temporal order, Global Structure, and Memory", "4) Temporal order, Global Structure, and Memory"),
            ("Lecture 4 b - Temporal Order, Global Structure, and Memory", "4B) Temporal Order, Global Structure, and Memory", "4B) Temporal Order, Global Structure, and Memory"),
            ("Lecture 7  part B - Fold Change Detection", "7) Fold Change Detection", "7) Fold Change Detection"),
            ("Lecture 8 C - Dynamic Compensation", "8A) Dynamic Compensation", "8A) Dynamic Compensation")
        ]

        for (original, aiTitle, expected) in cases {
            #expect(StudioViewModel.cleanedPlaylistLectureTitle(
                originalTitle: original,
                aiTitle: aiTitle,
                courseName: "Systems Biology"
            ) == expected)
        }
    }

    @Test("Deterministic playlist cleanup preserves parts when AI cleanup is unavailable")
    func deterministicPlaylistCleanupPreservesParts() {
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 5 a - Robustness using bifunctional components",
            aiTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 5 a - Robustness using bifunctional components")
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 5 - Part 2 - Robustness using bifunctional components",
            aiTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 5 - Part 2 - Robustness using bifunctional components")
    }

    @Test("Playlist title cleanup keeps every video title unique")
    func playlistTitleCleanupKeepsEveryVideoTitleUnique() {
        let items = [
            YouTubePlaylistItem(videoId: "part-a", title: "Lecture 3 Part a - Feed Forward Loops", playlistIndex: 3),
            YouTubePlaylistItem(videoId: "part-b", title: "Lecture 3 - Part b - Feed Forward Loops", playlistIndex: 4),
            YouTubePlaylistItem(videoId: "repeat-1", title: "Bonus discussion", playlistIndex: 5),
            YouTubePlaylistItem(videoId: "repeat-2", title: "Bonus discussion", playlistIndex: 6)
        ]
        let titles = StudioViewModel.uniquePlaylistLectureTitles(
            items,
            aiTitles: [
                "part-a": "3) Feed Forward Loops",
                "part-b": "3) Feed Forward Loops",
                "repeat-1": "5) Bonus discussion",
                "repeat-2": "5) Bonus discussion"
            ],
            courseName: "Systems Biology"
        )

        #expect(titles["part-a"] == "3) Feed Forward Loops · Video 3")
        #expect(titles["part-b"] == "3) Feed Forward Loops · Video 4")
        #expect(titles["repeat-1"] == "5) Bonus discussion · Video 5")
        #expect(titles["repeat-2"] == "5) Bonus discussion · Video 6")
        #expect(Set(titles.values).count == items.count)

        let sourceTitles = StudioViewModel.uniquePlaylistSourceTitles(
            items,
            lectureTitles: titles,
            courseName: "Systems Biology"
        )
        #expect(sourceTitles["part-a"] == "3) Feed Forward Loops · Video 3")
        #expect(sourceTitles["part-b"] == "3) Feed Forward Loops · Video 4")
        #expect(Set(sourceTitles.values).count == items.count)
    }

    @Test("Video source titles stay unique when lecture numbers were their only difference")
    func videoSourceTitlesStayUniqueWithoutLectureNumbers() {
        let items = [
            YouTubePlaylistItem(videoId: "first", title: "Lecture 1 - Introduction", playlistIndex: 1),
            YouTubePlaylistItem(videoId: "second", title: "Lecture 2 - Introduction", playlistIndex: 2)
        ]
        let titles = StudioViewModel.uniquePlaylistSourceTitles(
            items,
            lectureTitles: [
                "first": "1) Introduction",
                "second": "2) Introduction"
            ],
            courseName: "Systems Biology"
        )

        #expect(titles["first"] == "1) Introduction")
        #expect(titles["second"] == "2) Introduction")
    }

    @Test("Course refresh repairs only titles previously produced by the importer")
    func courseRefreshRepairsPreviouslyImportedVideoTitles() {
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "Feed Forward Loops",
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            replacementTitle: "Feed Forward Loops · Part A",
            courseName: "Systems Biology"
        ))
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "Bonus discussion",
            originalTitle: "Bonus discussion",
            cleanedLectureTitle: "5) Bonus discussion · Video 5",
            replacementTitle: "Bonus discussion · Video 5",
            courseName: "Systems Biology"
        ))
        #expect(!StudioViewModel.shouldRepairCoursePlaylistStoredTitle(
            currentTitle: "My renamed feed-forward lecture",
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            replacementTitle: "Feed Forward Loops · Part A",
            courseName: "Systems Biology"
        ))
    }

    @Test("Playlist lecture cleanup leaves semantic validation to the configured LLM")
    func playlistLectureCleanupLeavesSemanticValidationToLLM() {
        #expect(StudioViewModel.cleanedPlaylistLectureTitle(
            originalTitle: "Lecture 9 - How to build a Biological Oscillator",
            aiTitle: "9A) How to build a Biological Oscillator",
            courseName: "Systems Biology"
        ) == "9A) How to build a Biological Oscillator")
    }

    @Test("Playlist source display titles omit synthetic lecture numbers")
    func playlistSourceDisplayTitlesOmitSyntheticLectureNumbers() {
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Opening Remarks by Michael Dowling",
            cleanedLectureTitle: "1) Opening Remarks by Michael Dowling",
            courseName: "Quantum Biology"
        ) == "1) Opening Remarks by Michael Dowling")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Session 2 - Introduction by Session Leader",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "Session 2 - Introduction by Session Leader")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Quantum Biology / 2) Biophotons: Fundamentals",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "Quantum Biology / 2) Biophotons: Fundamentals")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "A 30,000 ft Overview",
            cleanedLectureTitle: nil,
            courseName: "Quantum Biology"
        ) == "A 30,000 ft Overview")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: "3A) Feed Forward Loops",
            courseName: "Systems Biology"
        ) == "3A) Feed Forward Loops")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 3 Part a - Feed Forward Loops",
            cleanedLectureTitle: nil,
            courseName: "Systems Biology"
        ) == "Lecture 3 Part a - Feed Forward Loops")
        #expect(StudioViewModel.playlistSourceDisplayTitle(
            originalTitle: "Lecture 5 Part 2 - Robustness",
            cleanedLectureTitle: "5.2) Robustness",
            courseName: "Systems Biology"
        ) == "5.2) Robustness")
    }

    @Test("Video playlist display title never numbers an already numbered title twice")
    func videoPlaylistDisplayTitleKeepsStoredOrdinal() {
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "1) Quantum Biology: A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: 1
        ) == "1) Quantum Biology: A 30,000 ft Overview")
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "1) Quantum Biology: A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: nil
        ) == "1) Quantum Biology: A 30,000 ft Overview")
    }

    @Test("Playlist rows number only titles that name no lecture of their own")
    func playlistRowsNumberOnlyUnnumberedTitles() {
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "A 30,000 ft Overview",
            playlistTitle: "Quantum Biology",
            sortIndex: 1
        ) == "2) A 30,000 ft Overview")
        #expect(StudioViewModel.videoPlaylistDisplayTitle(
            storedTitle: "3 Body Problem",
            playlistTitle: "Quantum Biology",
            sortIndex: 0
        ) == "1) 3 Body Problem")
    }

    @Test("Course lecture rows never repeat the number their title already carries")
    func courseLectureRowsDoNotRepeatTheirNumber() {
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 1,
            lectureTitle: "1) Universal Patterns of Aging",
            itemTitle: "1) Universal Patterns of Aging"
        ) == "1) Universal Patterns of Aging")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "Lecture 3: Age-Related Diseases",
            itemTitle: "Lecture 3: Age-Related Diseases"
        ) == "Lecture 3: Age-Related Diseases")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 4,
            lectureTitle: "Menopause",
            itemTitle: "Menopause"
        ) == "4) Menopause")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 4,
            lectureTitle: nil,
            itemTitle: ""
        ) == "4)")
    }

    @Test("Split lecture rows keep the part their videos are numbered by")
    func splitLectureRowsKeepVideoParts() {
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Feed Forward Loops",
            itemTitle: "3A) Feed Forward Loops"
        ) == "3A) Feed Forward Loops")
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Feed Forward Loops",
            itemTitle: "3B) Feed Forward Loops"
        ) == "3B) Feed Forward Loops")
        // A retitled lecture names the row; the video title does not override it.
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 3,
            lectureTitle: "3) Network motifs, continued",
            itemTitle: "3A) Feed Forward Loops"
        ) == "3) Network motifs, continued")
        // A lecture with no title of its own falls back to the video's.
        #expect(StudioViewModel.courseLectureRowTitle(
            lectureNumber: 8,
            lectureTitle: nil,
            itemTitle: "8C) Dynamic Compensation"
        ) == "8C) Dynamic Compensation")
    }

    @Test("Schedule video playlist rows use playlist metadata titles")
    func scheduleVideoPlaylistRowsUsePlaylistMetadataTitles() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let video = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "1) Quantum Biology: A 30,000 ft Overview",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 1
        )
        vm.videoPlaylistMetadata = [
            "playlist": VideoPlaylistMetadata(title: "Quantum Biology", playlistURL: "https://www.youtube.com/playlist?list=PL")
        ]
        vm.articles = [video]
        let goal = LearningGoalRecord(
            id: "goal",
            title: "Schedule",
            startAt: monday,
            endAt: calendar.date(byAdding: .day, value: 7, to: monday)!,
            createdAt: monday,
            updatedAt: monday,
            status: "active",
            items: []
        )
        // Schedule rows now come from shared placements (`scheduledSources`),
        // scoped to the goal via `goalIDs`, not from `goal.items`.
        vm.scheduledSources = [
            makeScheduledSourceEntry(sourceID: video.id, goalID: goal.id, plannedAt: monday)
        ]

        let item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == "Quantum Biology")
        #expect(item?.subtitle == "Quantum Biology")
        #expect(item?.title == "1) Quantum Biology: A 30,000 ft Overview")
    }

    @Test("opening a source never puts a completed row on the plan")
    func automaticActivityNeverAppearsAsPlannedWork() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let opened = makeArticle(url: "https://example.com/opened", title: "Opened Once")
        let planned = makeArticle(url: "https://example.com/planned", title: "Actually Planned")
        vm.articles = [opened, planned]

        // What the Reader writes when a source is merely opened: an automatic
        // placement anchoring that day's activity.
        vm.scheduledSources = [
            makeScheduledSourceEntry(
                sourceID: opened.id,
                goalID: "goal",
                plannedAt: monday,
                isAutomatic: true,
                activityKinds: [.reading]
            ),
            makeScheduledSourceEntry(sourceID: planned.id, goalID: "goal", plannedAt: monday),
        ]

        let day = vm.unifiedScheduleDays(containing: monday)
            .first { calendar.isDate($0.date, inSameDayAs: monday) }
        // Only the deliberate placement is on the plan, and it is not complete.
        #expect(day?.items.map(\.sourceID) == [planned.id])
        #expect(day?.completedCount == 0)
        #expect(day?.pendingCount == 1)
        #expect(day?.items.first?.canMarkDone == true)
    }

    @Test("activity on a planned day is a hint, not a completion")
    func activityOnPlannedDayDoesNotCompleteTheItem() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.com/planned", title: "Planned")
        vm.articles = [article]
        vm.scheduledSources = [
            makeScheduledSourceEntry(
                sourceID: article.id,
                goalID: "goal",
                plannedAt: monday,
                activityKinds: [.reading]
            )
        ]

        let item = vm.unifiedScheduleDays(containing: monday)
            .first { calendar.isDate($0.date, inSameDayAs: monday) }?
            .items.first
        #expect(item?.activityKinds == [.reading])
        #expect(item?.isCompleted == false)
    }

    @Test("Schedule book rows do not show opaque book IDs")
    func scheduleBookRowsDoNotShowOpaqueBookIDs() {
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let bookID = "82BDACDF-C0FA-4039-BE38-0C49BAB7D91D"
        let vm = makeViewModel()
        let chapter = makeArticle(
            url: "file:///Books/Quantum/Chapters/chapter-1.pdf",
            title: "1) Quantum Theory & The New Observables",
            sourceType: .book,
            parentGroup: bookID,
            sortIndex: 0
        )
        vm.articles = [chapter]
        let goal = LearningGoalRecord(
            id: "goal",
            title: "Schedule",
            startAt: monday,
            endAt: calendar.date(byAdding: .day, value: 7, to: monday)!,
            createdAt: monday,
            updatedAt: monday,
            status: "active",
            items: []
        )
        // Schedule rows now come from shared placements (`scheduledSources`),
        // scoped to the goal via `goalIDs`, not from `goal.items`.
        vm.scheduledSources = [
            makeScheduledSourceEntry(sourceID: chapter.id, goalID: goal.id, plannedAt: monday)
        ]

        var item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == nil)
        #expect(item?.subtitle == "Book chapter")

        vm.bookTitles[bookID] = "Quantum Theory"
        item = vm.scheduleDays(for: goal, containing: monday).first?.items.first
        #expect(item?.groupTitle == "Quantum Theory")
    }

    @Test("Video playlist items sort by playlist position")
    func videoPlaylistItemsSortByPlaylistPosition() {
        let vm = makeViewModel()
        let first = makeArticle(
            url: "https://www.youtube.com/watch?v=AAAAAAAAAAA",
            title: "First",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 0
        )
        let last = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "Last",
            sourceType: .video,
            parentGroup: "playlist",
            sortIndex: 46
        )
        vm.videoPlaylistMetadata = [
            "playlist": VideoPlaylistMetadata(title: "Playlist", playlistURL: "https://www.youtube.com/playlist?list=PL")
        ]
        vm.articles = [last, first]
        vm.sidebarTab = .videos

        #expect(vm.activeTabArticles.map(\.id) == [first.id, last.id])
    }

    @Test("Liked YouTube plugin videos render inline instead of as a playlist group")
    @MainActor
    func likedYouTubePluginVideosRenderInline() {
        let vm = makeViewModel()
        vm.videoPlaylistMetadata = [
            "liked": VideoPlaylistMetadata(
                title: "Liked videos",
                playlistURL: "https://www.youtube.com/playlist?list=LL",
                connectorKind: "liked"
            ),
            "playlist": VideoPlaylistMetadata(
                title: "Conference Talks",
                playlistURL: "https://www.youtube.com/playlist?list=PL"
            )
        ]

        #expect(vm.inlineVideoPlaylistGroupNames == ["liked"])
        #expect(vm.filteredVideoPlaylistGroupNames == ["playlist"])
    }

    @Test("ForeverLM plugin videos render inline")
    @MainActor
    func foreverLMPluginVideosRenderInline() {
        let vm = makeViewModel()
        vm.videoPlaylistMetadata = [
            "feynman": VideoPlaylistMetadata(
                title: "ForeverLM",
                playlistURL: "https://www.youtube.com/playlist?list=PL-feynman",
                autoImport: true,
                connectorKind: "foreverlm"
            ),
            "playlist": VideoPlaylistMetadata(
                title: "Conference Talks",
                playlistURL: "https://www.youtube.com/playlist?list=PL-other"
            )
        ]

        #expect(vm.inlineVideoPlaylistGroupNames == ["feynman"])
        #expect(vm.filteredVideoPlaylistGroupNames == ["playlist"])
    }

    @Test("ForeverLM playlist matching is exact but case insensitive")
    func foreverLMPlaylistTitleMatching() {
        #expect(YouTubeService.isForeverLMPlaylistTitle("ForeverLM"))
        #expect(YouTubeService.isForeverLMPlaylistTitle("  foreverlm\n"))
        #expect(!YouTubeService.isForeverLMPlaylistTitle("ForeverLM Queue"))
        #expect(!YouTubeService.isForeverLMPlaylistTitle("My ForeverLM"))
    }

    @Test("Named playlist removal only archives rows owned by that playlist")
    func foreverLMPlaylistRemovalIsGroupScoped() {
        let groupID = "playlist_youtube.com/playlist?list=PL-feynman"
        let removed = makeArticle(
            url: "https://www.youtube.com/watch?v=REMOVED0001",
            title: "Removed",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let retained = makeArticle(
            url: "https://www.youtube.com/watch?v=RETAINED001",
            title: "Retained",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let courseLecture = makeArticle(
            url: "https://www.youtube.com/watch?v=COURSE00001",
            title: "Course lecture",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: groupID
        )
        let current = Set([StudioViewModel.sourceURLIdentityKey(retained.url)])

        #expect(StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            removed,
            groupID: groupID,
            currentURLKeys: current
        ))
        #expect(!StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            retained,
            groupID: groupID,
            currentURLKeys: current
        ))
        #expect(!StudioViewModel.shouldArchiveMissingYouTubePlaylistVideo(
            courseLecture,
            groupID: groupID,
            currentURLKeys: current,
            courseLectureSourceIDs: [courseLecture.id]
        ))
    }

    @Test("Videos sort by publication date, with undated videos last")
    @MainActor
    func videoSortByPublishedDate() {
        let vm = makeViewModel()
        vm.videoSortMode = .published

        var old = makeArticle(url: "https://youtu.be/a", title: "Old", sourceType: .video, sortIndex: 0)
        old.videoPublishedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var recent = makeArticle(url: "https://youtu.be/b", title: "Recent", sourceType: .video, sortIndex: 1)
        recent.videoPublishedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        // No publish date — a Safari-discovered video, or one not yet re-synced.
        let undated = makeArticle(url: "https://youtu.be/c", title: "Undated", sourceType: .video, sortIndex: 2)

        let sorted = [old, undated, recent].sorted { vm.compareVideoArticles($0, $1) }
        #expect(sorted.map(\.title) == ["Recent", "Old", "Undated"])
    }

    @Test("Liked sort prefers the liked timestamp but falls back to playlist position")
    @MainActor
    func videoSortByLikedDateFallsBackToPlaylistPosition() {
        let vm = makeViewModel()
        vm.videoSortMode = .liked

        // Position says first, but the liked timestamp says older — the
        // timestamp wins when both rows have one.
        var first = makeArticle(url: "https://youtu.be/a", title: "First", sourceType: .video, sortIndex: 0)
        first.likedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var second = makeArticle(url: "https://youtu.be/b", title: "Second", sourceType: .video, sortIndex: 1)
        second.likedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        #expect([first, second].sorted { vm.compareVideoArticles($0, $1) }.map(\.title) == ["Second", "First"])

        // Neither has a timestamp yet: position still orders them.
        let a = makeArticle(url: "https://youtu.be/c", title: "A", sourceType: .video, sortIndex: 0)
        let b = makeArticle(url: "https://youtu.be/d", title: "B", sourceType: .video, sortIndex: 1)
        #expect([b, a].sorted { vm.compareVideoArticles($0, $1) }.map(\.title) == ["A", "B"])
    }

    @Test("Browser Reading List YouTube videos and X posts never become sources")
    func browserReadingListPluginURLsNeverBecomeSources() {
        let readingListVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=AAAAAAAAAAA",
            title: "Reading List video",
            sourceType: .video,
            discoveryOrigin: .safari
        )
        let readingListXPost = makeArticle(
            url: "https://x.com/someone/status/1234567890",
            title: "Reading List X post",
            sourceType: .xPost,
            discoveryOrigin: .safari
        )
        let readingListArticle = makeArticle(
            url: "https://example.com/article",
            title: "Reading List article",
            sourceType: .article,
            discoveryOrigin: .safari
        )
        let manualVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=BBBBBBBBBBB",
            title: "Manual video",
            sourceType: .video,
            discoveryOrigin: .manual
        )
        let sources = [readingListVideo, readingListXPost, readingListArticle, manualVideo]

        #expect(StudioViewModel.filterBrowserReadingListPluginSources(sources)
            .map(\.id) == [readingListArticle.id, manualVideo.id])
    }

    @Test("Videos tab refresh never scans browser Reading Lists")
    func videosTabRefreshNeverScansBrowserReadingLists() {
        #expect(!StudioViewModel.discoveryScanIncludesBrowserReadingLists(.videos))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(.articles))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(.papers))
        #expect(!StudioViewModel.discoveryScanIncludesBrowserReadingLists(.books))
        #expect(StudioViewModel.discoveryScanIncludesBrowserReadingLists(nil))
    }

    @Test("Videos tab mirrors the liked feed")
    func videosTabMirrorsTheLikedFeed() {
        let syncedVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=SYNCEDVID01",
            title: "A liked video",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )

        let feedWithoutIt = Set([
            StudioViewModel.sourceURLIdentityKey("https://www.youtube.com/watch?v=OTHERVIDEO1"),
        ])
        let feedWithIt = Set([
            StudioViewModel.sourceURLIdentityKey(syncedVideo.url),
        ])

        // Gone from the feed → archive; still liked → keep.
        #expect(StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            syncedVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            syncedVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithIt
        ))

        // Videos in playlist groups (courses and playlist follows) are left alone.
        let playlistVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=PLAYLIST123",
            title: "Lecture 3",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: "some-course-playlist"
        )
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            playlistVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))

        // Manually added YouTube URLs are left alone.
        let manualVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=MANUALVID01",
            title: "Manually added talk",
            sourceType: .video,
            discoveryOrigin: .manual
        )
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            manualVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt
        ))

        // Videos discovered in a browser Reading List were never claimed to be
        // liked, so the Liked feed has no standing to archive them.
        for browserOrigin in [DiscoveryOrigin.safari, .chrome, .brave] {
            let browserVideo = makeArticle(
                url: "https://www.youtube.com/watch?v=BROWSERVID1",
                title: "Found while browsing",
                sourceType: .video,
                discoveryOrigin: browserOrigin
            )
            #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
                browserVideo,
                likedGroupID: "liked-group",
                likedURLKeys: feedWithoutIt
            ))
        }

        // Course-lecture videos are scraped from public playlists, so they
        // carry .youtubePlaylist origin and no parentGroup — exactly what the
        // predicate would otherwise archive. Membership in course_lecture_items
        // must exempt them; archiving wipes the lecture transcript.
        let lectureVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=LECTUREVID1",
            title: "1) The insulin-glucose circuit",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        #expect(StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            lectureVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt,
            courseLectureSourceIDs: []
        ))
        #expect(!StudioViewModel.shouldArchiveUnlikedYouTubeVideo(
            lectureVideo,
            likedGroupID: "liked-group",
            likedURLKeys: feedWithoutIt,
            courseLectureSourceIDs: [lectureVideo.id]
        ))
    }

    @Test("Manual removal outlives a stale like; only a re-like brings the video back")
    func manualRemovalOutlivesStaleLike() {
        let removedAt = Date(timeIntervalSinceReferenceDate: 5_000)

        // Still liked from before the removal — the sync must not resurrect it.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            dismissedAt: removedAt
        ))
        // Liked at the exact removal instant proves nothing fresh either.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: removedAt,
            dismissedAt: removedAt
        ))
        // Re-liked after the removal — the fresher intent wins.
        #expect(StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            dismissedAt: removedAt
        ))
        // No liked date at all — freshness unprovable, the removal stands.
        #expect(!StudioViewModel.likedFeedEntryOutranksDismissal(
            likedAt: nil,
            dismissedAt: removedAt
        ))
    }

    @Test("Dismissal dates collapse onto URL identity keys, latest removal winning")
    func dismissalDatesCollapseOntoIdentityKeys() {
        let byKey = StudioViewModel.dismissalDatesByIdentityKey([
            "https://www.youtube.com/watch?v=SYNCEDVID01": Date(timeIntervalSinceReferenceDate: 2_000),
            "https://youtu.be/SYNCEDVID01": Date(timeIntervalSinceReferenceDate: 7_000),
            "https://example.com/article": Date(timeIntervalSinceReferenceDate: 3_000),
        ])

        // Both spellings of the video normalize to one key; the later removal wins.
        let videoKey = StudioViewModel.sourceURLIdentityKey("https://www.youtube.com/watch?v=SYNCEDVID01")
        #expect(byKey[videoKey] == Date(timeIntervalSinceReferenceDate: 7_000))
        let articleKey = StudioViewModel.sourceURLIdentityKey("https://example.com/article")
        #expect(byKey[articleKey] == Date(timeIntervalSinceReferenceDate: 3_000))
        #expect(byKey.count == 2)
    }

    @Test("Course lecture list hides empty placeholder when real lectures start later")
    func courseLectureListHidesEmptyPlaceholderWhenRealLecturesStartLater() {
        let vm = makeViewModel()
        let courseName = "Biochemistry"
        vm.courseLecturesByCourse[courseName] = [
            CourseSession(id: "placeholder", courseName: courseName, number: 1),
            CourseSession(id: "lecture-12", courseName: courseName, number: 12, title: "Introduction to Membranes"),
        ]

        #expect(vm.courseLectures(for: courseName).map(\.number) == [12])
    }

    @Test("Creating a course does not create an assumed lecture one")
    func creatingCourseDoesNotCreateAssumedLectureOne() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CourseCreateNoPlaceholderTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        await vm.createCourse(name: "Biochemistry")

        #expect(vm.courseLecturesByCourse.values.flatMap { $0 }.isEmpty)
        #expect(try await service.loadCourseLectures().isEmpty)
    }

    @Test("Lettered lecture materials attach to the matching major lecture")
    func letteredMaterialsAttachToMajorLecture() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CoursePlaylistImportTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let courseName = "Systems Biology"

        guard let lecture = await vm.createLecture(in: courseName, title: "Temporal order", number: 5) else {
            Issue.record("Expected lecture 5 to be created")
            return
        }

        var partA = StudioArticle(url: "https://www.youtube.com/watch?v=AAAAAAAAAAA", title: "5A) Temporal order", sourceType: .video)
        var partB = StudioArticle(url: "https://www.youtube.com/watch?v=BBBBBBBBBBB", title: "5B) Temporal order", sourceType: .video)
        _ = try await service.insertSourceIfNew(&partA)
        _ = try await service.insertSourceIfNew(&partB)
        vm.articles = [partA, partB]

        await vm.addArticleToCourse(articleId: partA.id, courseName: courseName)
        await vm.addArticleToCourse(articleId: partB.id, courseName: courseName)

        #expect(vm.courseLectures(for: courseName).map(\.number) == [5])
        #expect(vm.courseLectureItems(for: lecture.id).compactMap(\.sourceId) == [partA.id, partB.id])
    }
}

@Suite("YouTube Metadata")
@MainActor
struct YouTubeMetadataTests {

    @Test("oEmbed metadata replaces browser placeholder fields")
    func oEmbedMetadataAppliesToSource() {
        var article = StudioArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "www.com",
            sourceType: .video
        )
        article.domain = "www.youtube.com"

        let metadata = YouTubeTranscriptService.VideoMetadata(
            title: "Discrete Diffusion Models",
            channelName: "MIT 6.S978",
            thumbnailURL: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        )

        StudioYouTubeMetadataApplicator.apply(metadata, to: &article)

        #expect(article.title == "Discrete Diffusion Models")
        #expect(article.domain == "MIT 6.S978")
        #expect(article.artworkURL == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    @Test("YouTube metadata falls back to deterministic thumbnail")
    func metadataUsesDeterministicThumbnailFallback() {
        var article = StudioArticle(
            url: "https://youtu.be/dQw4w9WgXcQ",
            title: "www.com",
            sourceType: .video
        )

        let metadata = YouTubeTranscriptService.VideoMetadata(
            title: "Discrete Diffusion Models",
            channelName: nil,
            thumbnailURL: nil
        )

        StudioYouTubeMetadataApplicator.apply(metadata, to: &article)

        #expect(article.title == "Discrete Diffusion Models")
        #expect(article.artworkURL == "https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }

    @Test("Placeholder YouTube titles are detected")
    func placeholderYouTubeTitlesAreBad() {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        #expect(StudioViewModel.titleLooksBad("www.com", domain: "www.youtube.com", url: url))
        #expect(StudioViewModel.titleLooksBad("Untitled Video", domain: "www.youtube.com", url: url))
        #expect(!StudioViewModel.titleLooksBad("Discrete Diffusion Models", domain: "www.youtube.com", url: url))
    }

    @Test("URL-shaped titles are bad even when they differ from the stored URL")
    func urlShapedTitlesAreBadWhenMismatched() {
        let storedURL = "https://open.substack.com/pub/couteiral/p/the-antibody-revolution-is-real-the"
        let readingListTitle = "https://couteiral.substack.com/p/the-antibody-revolution-is-real-the?utm_campaign=post"
        #expect(
            StudioViewModel.titleLooksBad(
                readingListTitle,
                domain: "open.substack.com",
                url: storedURL
            )
        )
    }

    @Test("HTML page metadata replaces placeholder article title and author")
    func applyWebArticleMetadataIfNeeded() {
        var article = StudioArticle(
            url: "https://open.substack.com/pub/couteiral/p/example",
            title: "https://couteiral.substack.com/p/example?utm_campaign=post",
            sourceType: .article
        )
        article.domain = "open.substack.com"
        StudioViewModel.applyWebArticleMetadataIfNeeded(
            to: &article,
            pageTitle: "The antibody revolution is real. The business, less so.",
            pageAuthor: "Carlos Outeiral",
            content: "Body text"
        )
        #expect(article.title == "The antibody revolution is real. The business, less so.")
        #expect(article.author == "Carlos Outeiral")
    }
}
