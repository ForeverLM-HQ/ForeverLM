// The tab management tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

@Suite("Tab Management")
@MainActor
struct TabManagementTests {
    @Test("an explainer is listed under the source it explains, never as a row of its own")
    func explainerFoldsUnderItsSource() {
        // The product owner (2026-09-10): "an explainer of an article shouldn't be stored
        // as a separate entity; it should just be linked to that original
        // article somehow". Storage is unchanged — the link is the explainer's
        // URL — and the sidebar folds it under its source (explainer-design.md).
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.org/a", title: "A", sourceType: .article, state: .ready, id: "art-1")
        let paper = makeArticle(url: "https://doi.org/10.1/x", title: "P", sourceType: .paper, state: .ready, id: "pap-1")
        let explainer = makeArticle(
            url: GeneratedExplainer.url(explaining: article.id),
            title: "Explainer: A",
            sourceType: .article,
            state: .ready,
            id: GeneratedExplainer.sourceID(explaining: article.id)
        )
        let paperExplainer = makeArticle(
            url: GeneratedExplainer.url(explaining: paper.id),
            title: "Explainer: P",
            sourceType: .article,
            state: .ready,
            id: GeneratedExplainer.sourceID(explaining: paper.id)
        )
        vm.articles = [article, paper, explainer, paperExplainer]

        // No tab lists an explainer as a row, though it is an article-typed source.
        for tab in StudioSidebarTab.allCases {
            #expect(!vm.sourceBelongsToTab(explainer, tab: tab), "\(tab)")
            #expect(!vm.sourceBelongsToTab(paperExplainer, tab: tab), "\(tab)")
        }
        vm.sidebarTab = .articles
        #expect(vm.matchesCurrentTab(article))
        #expect(!vm.matchesCurrentTab(explainer))
        #expect(!vm.matchesCurrentTab(paperExplainer))
        #expect(vm.activeTabArticles.map(\.id) == [article.id])

        // The source's row finds its explainer without scanning the library,
        // and the explainer knows its source.
        #expect(vm.explainer(explaining: article.id)?.id == explainer.id)
        #expect(vm.explainer(explaining: paper.id)?.id == paperExplainer.id)
        #expect(vm.explainer(explaining: explainer.id) == nil)
        #expect(vm.explainedSource(of: explainer)?.id == article.id)
        #expect(vm.explainedSource(of: article) == nil)

        // Revealing an explainer goes to the tab of the source it is folded
        // under: a paper's explainer is revealed in Papers, not Articles.
        #expect(vm.sidebarTab(listing: explainer) == .articles)
        #expect(vm.sidebarTab(listing: paperExplainer) == .papers)
        #expect(vm.sidebarTab(listing: paper) == .papers)

        // Deleting the source takes the row's explainer lookup with it.
        vm.articles = [article, paper, paperExplainer]
        #expect(vm.explainer(explaining: article.id) == nil)
        #expect(vm.explainer(explaining: paper.id)?.id == paperExplainer.id)

        // An explainer whose source is gone has no row anywhere to reveal.
        vm.articles = [paperExplainer]
        #expect(vm.sidebarTab(listing: paperExplainer) == nil)
    }


    @Test("switchTab changes sidebarTab")
    func switchTabChanges() {
        let vm = makeViewModel()
        vm.sidebarTab = .articles
        vm.switchTab(to: .papers)
        #expect(vm.sidebarTab == .papers)
    }

    @Test("a Zoom recording is a meeting session, not a video")
    func zoomRecordingsAreMeetings() {
        let vm = makeViewModel()
        vm.meetingMetadata = ["zoom:stanford.zoom.us": MeetingMetadata(title: "stanford.zoom.us")]
        var zoomRecording = makeArticle(
            url: "https://stanford.zoom.us/rec/share/recording-token",
            sourceType: .meeting,
            id: "zoom-recording"
        )
        zoomRecording.parentGroup = "zoom:stanford.zoom.us"
        zoomRecording.discoveryOrigin = .zoom
        let youtubeVideo = makeArticle(
            url: "https://www.youtube.com/watch?v=VIDEO123456",
            sourceType: .video,
            id: "youtube-video"
        )
        vm.articles = [zoomRecording, youtubeVideo]

        #expect(vm.sourceBelongsToTab(zoomRecording, tab: .meetings))
        #expect(!vm.sourceBelongsToTab(zoomRecording, tab: .videos))
        #expect(vm.sourceBelongsToTab(youtubeVideo, tab: .videos))
        #expect(!vm.sourceBelongsToTab(youtubeVideo, tab: .meetings))

        vm.sidebarTab = .meetings
        #expect(vm.matchesCurrentTab(zoomRecording))
        #expect(!vm.matchesCurrentTab(youtubeVideo))

        vm.sidebarTab = .videos
        #expect(!vm.matchesCurrentTab(zoomRecording))
        #expect(vm.matchesCurrentTab(youtubeVideo))

        // Provider is read off the session, so the row wears the Zoom mark and
        // answers the Zoom filter without a tab of its own.
        #expect(MeetingProvider.forOrigin(zoomRecording.discoveryOrigin) == .zoom)
        #expect(vm.meetingGroupProviders("zoom:stanford.zoom.us") == [.zoom])
    }

    @Test("a Zoom recording still stored as a video is not stranded in YouTube")
    func syncedZoomVideoRoutesToMeetings() {
        // Web Studio can only record the broad `video` type, and an older build
        // filed recordings under a Zoom tab. Either way the family is Meetings.
        #expect(
            StudioSidebarTab.knowledgeTab(
                sourceType: .video,
                url: "https://stanford.zoom.us/rec/share/recording-token"
            ) == .meetings
        )
        #expect(
            StudioSidebarTab.knowledgeTab(
                sourceType: .video,
                url: "https://www.youtube.com/watch?v=VIDEO123456"
            ) == .videos
        )
    }

    @Test("a pasted Zoom link joins the series for its Zoom account")
    func zoomRecordingJoinsHostSeries() async {
        let vm = makeViewModel()
        var first = makeArticle(
            url: "https://stanford.zoom.us/rec/share/one",
            sourceType: .meeting,
            id: "zoom-one"
        )
        var second = makeArticle(
            url: "https://stanford.zoom.us/rec/play/two",
            sourceType: .meeting,
            id: "zoom-two"
        )
        await vm.assignZoomMeetingSeries(to: &first, explicit: true)
        await vm.assignZoomMeetingSeries(to: &second, explicit: true)

        // Two occurrences of the same seminar, one row — which is the whole
        // reason a recording had to stop being a video.
        #expect(first.parentGroup == "zoom:stanford.zoom.us")
        #expect(second.parentGroup == first.parentGroup)
        #expect(first.discoveryOrigin == .zoom)
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.title == "stanford.zoom.us")
    }

    @Test("a Zoom recording joins a series that already answers to its name")
    func zoomRecordingAdoptsExistingSeries() async {
        let vm = makeViewModel()
        // A series already standing under this name takes the session instead of
        // a second row appearing beside it.
        vm.meetingMetadata = ["existing-series": MeetingMetadata(title: "stanford.zoom.us")]
        var recording = makeArticle(
            url: "https://stanford.zoom.us/rec/share/three",
            sourceType: .meeting,
            id: "zoom-three"
        )
        await vm.assignZoomMeetingSeries(to: &recording, explicit: true)
        #expect(recording.parentGroup == "existing-series")
        #expect(vm.meetingMetadata.count == 1)
    }

    @Test("a pasted Zoom link lifts a removed series; an adopted row leaves it removed")
    func zoomRecordingRespectsARemovedSeries() async {
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
        // What removeMeetingGroup leaves behind for a Zoom-account series once
        // the series row itself has been deleted.
        UserDefaults.standard.set(["group:zoom:stanford.zoom.us"], forKey: identityKey)
        UserDefaults.standard.set(["stanford.zoom.us"], forKey: titleKey)
        let vm = makeViewModel()

        // A row adopted from sync or an older build is nobody asking for the
        // series back: it is filed, but the series stays out of sight.
        var adopted = makeArticle(
            url: "https://stanford.zoom.us/rec/share/synced",
            sourceType: .video,
            id: "zoom-synced"
        )
        await vm.assignZoomMeetingSeries(to: &adopted, explicit: false)
        #expect(adopted.parentGroup == "zoom:stanford.zoom.us")
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.isHidden == true)
        #expect(!vm.visibleMeetingGroupNames.contains("zoom:stanford.zoom.us"))
        #expect(StudioViewModel.isMeetingGroupTitleRemoved("stanford.zoom.us"))

        // A link the learner pastes is the learner asking for the series.
        var pasted = makeArticle(
            url: "https://stanford.zoom.us/rec/share/pasted",
            sourceType: .meeting,
            id: "zoom-pasted"
        )
        await vm.assignZoomMeetingSeries(to: &pasted, explicit: true)
        #expect(pasted.parentGroup == "zoom:stanford.zoom.us")
        #expect(vm.meetingMetadata["zoom:stanford.zoom.us"]?.isHidden == false)
        #expect(!StudioViewModel.isMeetingGroupTitleRemoved("stanford.zoom.us"))
        #expect(!Set(StudioViewModel.loadRemovedMeetingGroupIdentities()).contains("group:zoom:stanford.zoom.us"))
    }

    @Test("switchTab resets searchText")
    func switchTabResetsSearch() {
        let vm = makeViewModel()
        vm.searchText = "some query"
        vm.switchTab(to: .podcasts)
        #expect(vm.searchText == "")
    }

    @Test("switchTab resets displayLimit to 40")
    func switchTabResetsDisplayLimit() {
        let vm = makeViewModel()
        vm.displayLimit = 120
        vm.switchTab(to: .books)
        #expect(vm.displayLimit == 40)
    }

    @Test("switchTab resets articleOriginFilter")
    func switchTabResetsArticleOriginFilter() {
        let vm = makeViewModel()
        vm.articleOriginFilter = .safari
        vm.switchTab(to: .papers)
        #expect(vm.articleOriginFilter == nil)
    }

    /// The sources panel is a filter over the library, not a statement about what is being
    /// read. Switching to Papers — which adding a cited paper does on its own — used to close
    /// the video that cited it.
    @Test("switchTab keeps the source the reader has open")
    func switchTabKeepsOpenSource() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleId == "video-1")
    }

    @Test("switchTab drops a list selection the new tab doesn't show")
    func switchTabPrunesListSelection() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleIds = ["video-1"]

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleIds.isEmpty)
    }

    /// Coming back to the tab the open source lives in should land on a highlighted row, not
    /// a list with nothing marked under a reader that is plainly showing one of its items.
    @Test("switchTab re-marks the open source when it belongs to the new tab")
    func switchTabRemarksOpenSource() {
        let vm = makeViewModel()
        vm.articles = [makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1")]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"
        vm.switchTab(to: .papers)

        vm.switchTab(to: .videos)

        #expect(vm.selectedArticleIds == ["video-1"])
    }

    /// Only fills an empty selection: a multi-selection that survived the filter is the
    /// user's, and collapsing it onto the reader's source would discard it.
    @Test("switchTab leaves a surviving multi-selection alone")
    func switchTabKeepsSurvivingMultiSelection() {
        let vm = makeViewModel()
        vm.articles = [
            makeArticle(url: "https://a.example/paper", sourceType: .paper, id: "paper-1"),
            makeArticle(url: "https://b.example/paper", sourceType: .paper, id: "paper-2"),
            makeArticle(url: "https://youtu.be/abc", sourceType: .video, id: "video-1"),
        ]
        vm.switchTab(to: .videos)
        vm.selectedArticleId = "video-1"
        vm.selectedArticleIds = ["paper-1", "paper-2"]

        vm.switchTab(to: .papers)

        #expect(vm.selectedArticleIds == ["paper-1", "paper-2"])
    }

    @Test("hideTab adds to hiddenTabs")
    func hideTabAdds() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        vm.hideTab(.videos)
        #expect(vm.hiddenTabs.contains(.videos))
    }

    @Test("hideTab switches away if current tab is hidden")
    func hideTabSwitchesAway() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        vm.tabOrder = StudioSidebarTab.allCases
        vm.sidebarTab = .videos
        vm.hideTab(.videos)
        #expect(vm.sidebarTab != .videos)
    }

    @Test("hideTab keeps the last pinned tab on the bar")
    func hideTabKeepsLastPinnedTab() {
        let vm = makeViewModel()
        vm.tabOrder = StudioSidebarTab.allCases
        vm.hiddenTabs = Set(StudioSidebarTab.allCases).subtracting([.papers])
        #expect(!vm.canUnpinTab(.papers))
        vm.hideTab(.papers)
        #expect(vm.visibleTabs == [.papers])
    }

    @Test("canUnpinTab allows a tab while another stays pinned, and any hidden tab")
    func canUnpinTabWithCompany() {
        let vm = makeViewModel()
        vm.hiddenTabs = []
        #expect(vm.canUnpinTab(.papers))
        vm.hideTab(.papers)
        #expect(vm.hiddenTabs.contains(.papers))
        // A hidden tab is always allowed through: the answer gates unpinning,
        // never pinning back.
        #expect(vm.canUnpinTab(.papers))
    }

    @Test("showTab removes from hiddenTabs")
    func showTabRemoves() {
        let vm = makeViewModel()
        vm.hiddenTabs = [.books, .meetings]
        vm.showTab(.books)
        #expect(!vm.hiddenTabs.contains(.books))
        #expect(vm.hiddenTabs.contains(.meetings))
    }

    @Test("reorderTab moves tab position")
    func reorderTabMoves() {
        let vm = makeViewModel()
        vm.tabOrder = [.articles, .papers, .books, .podcasts, .videos]
        vm.reorderTab(from: .podcasts, to: .articles)
        #expect(vm.tabOrder.first == .podcasts)
    }

    @Test("reconciledOrder completes a partial order without dropping tabs")
    func reconciledOrderCompletesPartialOrder() {
        // The shape that emptied the tab bar: a synced order naming only three
        // tabs. Membership belongs to hiddenTabs, so the rest must come back.
        let order = StudioSidebarTab.reconciledOrder([.podcasts, .books, .articles])
        // The three keep their order; Meetings, missing, slots in after Books.
        #expect(order.filter { [.podcasts, .books, .articles].contains($0) } == [.podcasts, .books, .articles])
        #expect(order.firstIndex(of: .meetings) == order.firstIndex(of: .books).map { $0 + 1 })
        for tab in StudioSidebarTab.allCases {
            #expect(order.contains(tab))
        }
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("reconciledOrder drops duplicates and slots Meetings after Books")
    func reconciledOrderDedupesAndAnchors() {
        let order = StudioSidebarTab.reconciledOrder([.books, .books, .papers])
        #expect(order.filter { $0 == .books }.count == 1)
        if let books = order.firstIndex(of: .books), books + 1 < order.count {
            #expect(order[books + 1] == .meetings)
        } else {
            Issue.record("Books missing from reconciled order")
        }
    }

    @Test("a stored order or hidden set naming the retired Courses tab drops it")
    func persistedCoursesTabIsDropped() {
        // Courses moved to the rail (courses-design.md); "Courses" names no tab.
        #expect(StudioSidebarTab.fromPersistedRawValue("Courses") == nil)
        let order = StudioSidebarTab.reconciledOrder(
            ["Articles", "Courses", "Papers"].compactMap(StudioSidebarTab.fromPersistedRawValue)
        )
        #expect(order.prefix(2) == [.articles, .papers])
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("a saved order naming the retired Zoom tab keeps Meetings' position")
    func persistedZoomTabResolvesToMeetings() {
        #expect(StudioSidebarTab.fromPersistedRawValue("Zoom") == .meetings)
        // Drive, Read AI and Zoom all collapse onto one tab, so an order naming
        // every one of them yields Meetings once rather than three times.
        let order = StudioSidebarTab.reconciledOrder(
            ["Google Drive", "Read AI", "Zoom"].compactMap(StudioSidebarTab.fromPersistedRawValue)
        )
        #expect(order.filter { $0 == .meetings }.count == 1)
        #expect(order.first == .meetings)
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("assigning a partial tabOrder self-heals instead of persisting truncation")
    func tabOrderAssignmentReconciles() {
        let vm = makeViewModel()
        vm.tabOrder = [.podcasts, .books, .articles]
        #expect(vm.tabOrder.count == StudioSidebarTab.allCases.count)
        #expect(vm.tabOrder.contains(.papers))
        #expect(vm.tabOrder.contains(.videos))
        #expect(vm.tabOrder.contains(.meetings))
    }

    @Test("a partial tabOrder still leaves unhidden tabs visible")
    func visibleTabsSurvivePartialOrder() {
        let vm = makeViewModel()
        vm.hiddenTabs = [.xPosts, .meetings]
        vm.tabOrder = [.podcasts, .books, .articles]
        #expect(vm.visibleTabs.contains(.papers))
        #expect(vm.visibleTabs.contains(.videos))
        #expect(!vm.visibleTabs.contains(.xPosts))
    }

    @Test("a series fed by two providers is one row wearing both marks")
    func mixedProviderSeriesListedOnce() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = ["weekly": MeetingMetadata(title: "Weekly Sync", recurrenceRule: "Every Monday")]
        vm.articles = [
            makeArticle(
                url: "https://drive.google.com/file/d/rec",
                title: "Recording",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings,
                parentGroup: "weekly"
            ),
            makeArticle(
                url: "https://app.read.ai/analytics/meetings/notes",
                title: "Notes",
                sourceType: .meeting,
                discoveryOrigin: .readAI,
                parentGroup: "weekly"
            ),
        ]

        // Under the split Google Drive / Read AI tabs this series was listed
        // twice, once under each tab, because provider decided membership.
        #expect(vm.filteredMeetingGroupNames == ["weekly"])
        #expect(vm.meetingGroupProviders("weekly") == [.googleDrive, .readAI])
        #expect(vm.meetingProvidersInUse == [.googleDrive, .readAI])
        #expect(vm.meetingSessionCountsByProvider[.googleDrive] == 1)
        #expect(vm.meetingSessionCountsByProvider[.readAI] == 1)
    }

    @Test("the provider filter narrows Meetings without deciding membership")
    func meetingProviderFilterNarrows() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "weekly": MeetingMetadata(title: "Weekly Sync"),
            "readonly": MeetingMetadata(title: "Read AI Only"),
        ]
        let drive = makeArticle(
            url: "https://drive.google.com/file/d/rec",
            title: "Recording",
            sourceType: .meeting,
            discoveryOrigin: .googleDriveMeetings,
            parentGroup: "weekly"
        )
        let readAI = makeArticle(
            url: "https://app.read.ai/analytics/meetings/notes",
            title: "Notes",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: "readonly"
        )
        vm.articles = [drive, readAI]

        // No filter: every provider's series is present. This is the default.
        #expect(vm.filteredMeetingGroupNames.count == 2)
        #expect(vm.matchesCurrentTab(drive))
        #expect(vm.matchesCurrentTab(readAI))

        vm.meetingProviderFilter = .readAI
        #expect(vm.filteredMeetingGroupNames == ["readonly"])
        #expect(!vm.matchesCurrentTab(drive))
        #expect(vm.matchesCurrentTab(readAI))
        #expect(vm.hasActiveSourceListFilters)

        // Clearing the source-list filters clears the provider with them: the
        // chip lives in that popover, so "Clear" has to reach it.
        vm.clearSourceListFilters()
        #expect(vm.meetingProviderFilter == nil)
        #expect(vm.filteredMeetingGroupNames.count == 2)
    }

    @Test("by date, Meetings lists every session newest first across series, a page at a time")
    func meetingsByDateListsSessionsAcrossSeries() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "alpha": MeetingMetadata(title: "Alpha Group"),
            "beta": MeetingMetadata(title: "Beta Group"),
        ]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        vm.articles = (0..<45).map { index in
            var session = makeArticle(
                url: "https://example.org/session/\(index)",
                title: "Session \(index)",
                sourceType: .meeting,
                discoveryOrigin: .localMeetings,
                parentGroup: index.isMultiple(of: 2) ? "alpha" : "beta",
                id: "session-\(index)"
            )
            session.dateAdded = start.addingTimeInterval(Double(index) * 86_400)
            return session
        }

        // By series, the tab renders whole groups and never pages.
        #expect(vm.meetingListOrder == .bySeries)
        #expect(vm.activeTabArticles.count == 45)
        #expect(!vm.hasMoreItems)
        #expect(vm.totalFilteredCount == 2)

        vm.meetingListOrder = .byDate
        defer { vm.meetingListOrder = .bySeries }

        let page = vm.activeTabArticles
        #expect(page.count == 40)
        #expect(page.first?.id == "session-44")
        #expect(page.map(\.dateAdded) == page.map(\.dateAdded).sorted(by: >))
        // Neighbouring rows come from different series: the list is not grouped.
        #expect(Set(page.prefix(2).compactMap(\.parentGroup)) == ["alpha", "beta"])
        #expect(vm.hasMoreItems)
        #expect(vm.remainingItemCount == 5)
        #expect(vm.totalFilteredCount == 45)

        vm.showMore()
        #expect(vm.activeTabArticles.count == 45)
        #expect(!vm.hasMoreItems)
    }

    @Test("a session row names its series and its day when listed among other series")
    func meetingSeriesRowTitleNamesTheSeries() {
        let vm = makeViewModel()
        vm.meetingMetadata = ["alpha": MeetingMetadata(title: "Alpha Group")]
        let dated = makeArticle(title: "2026/05/10 08:00 PDT", sourceType: .meeting, parentGroup: "alpha")
        let named = makeArticle(title: "Journal club on ion channels", sourceType: .meeting, parentGroup: "alpha")

        #expect(vm.meetingSeriesRowTitle(for: dated) == "Alpha Group")
        #expect(vm.meetingSeriesRowTitle(for: named) == "Alpha Group — Journal club on ion channels")
        #expect(!vm.meetingSessionWhen(for: dated).isEmpty)
    }

    @Test("the reader names a session's series beside its day or topic")
    func meetingStandaloneTitleNamesTheSeries() {
        let vm = makeViewModel()
        vm.meetingMetadata = ["alpha": MeetingMetadata(title: "Alpha Group")]
        let dated = makeArticle(title: "2026/10/25", sourceType: .meeting, parentGroup: "alpha")
        let prefixed = makeArticle(title: "Alpha Group - 2026/10/25", sourceType: .meeting, parentGroup: "alpha")
        let named = makeArticle(title: "Journal club on ion channels", sourceType: .meeting, parentGroup: "alpha")
        let loose = makeArticle(title: "2026/10/25", sourceType: .meeting, parentGroup: nil)
        let video = makeArticle(title: "A talk", sourceType: .video, parentGroup: "alpha")

        let day = vm.meetingRowTitle(for: dated).text
        #expect(day != "2026/10/25")
        #expect(vm.standaloneTitle(for: dated) == "Alpha Group — \(day)")
        #expect(vm.standaloneTitle(for: prefixed) == "Alpha Group — \(day)")
        #expect(vm.standaloneTitle(for: named) == "Alpha Group — Journal club on ion channels")
        #expect(vm.standaloneTitle(for: loose) == day)
        #expect(vm.standaloneTitle(for: video) == "A talk")
    }

    @Test("a folder imported from this Mac is visible in Meetings")
    func locallyImportedMeetingIsVisible() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = ["offsite": MeetingMetadata(title: "Offsite", localFolderPath: "/Users/me/Recordings")]
        let local = makeArticle(
            url: "file:///Users/me/Recordings/day1.txt",
            title: "Day 1",
            sourceType: .meeting,
            discoveryOrigin: .localMeetings,
            parentGroup: "offsite"
        )
        vm.articles = [local]

        // The split tabs left `localMeetings` with no home: Read AI did not claim
        // it and Google Drive only did after a repair, so a folder imported from
        // disk was briefly invisible everywhere.
        #expect(vm.filteredMeetingGroupNames == ["offsite"])
        #expect(vm.matchesCurrentTab(local))
        #expect(vm.meetingGroupProviders("offsite") == [.localFolder])
    }

    @Test("a linked Drive folder still names its provider with no active sessions")
    func archivedSeriesKeepsItsProvider() {
        let vm = makeViewModel()
        vm.sidebarTab = .meetings
        vm.meetingMetadata = [
            "weekly": MeetingMetadata(
                title: "Weekly Sync",
                driveFolderURL: "https://drive.google.com/drive/folders/abc"
            )
        ]
        vm.articles = []

        // A connected folder whose sessions had all been archived belonged to no
        // tab at all, so the Drive tab rendered its never-connected empty state
        // over a folder that was in fact connected.
        #expect(vm.filteredMeetingGroupNames == ["weekly"])
        #expect(vm.meetingGroupProviders("weekly") == [.googleDrive])
    }

    @Test("re-importing a meeting folder preserves its user-renamed title")
    func meetingFolderReimportPreservesRenamedTitle() async throws {
        let vm = makeViewModel()
        let groupID = "weekly"
        let folderURL = "https://drive.google.com/drive/folders/folder-123"
        let renamedTitle = "Biostasis Working Group Sync"
        vm.meetingMetadata = [
            groupID: MeetingMetadata(title: renamedTitle, driveFolderURL: folderURL)
        ]
        try await vm.storage.saveMeetingGroup(
            name: groupID,
            metadata: try #require(vm.meetingMetadata[groupID])
        )

        // A later plugin refresh reports the provider-owned folder name
        // again. That discovery title must not replace the learner's rename.
        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "[EF] Biostasis Working Group Sync (15 mins)",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: true
        )

        #expect(vm.meetingMetadata[groupID]?.title == renamedTitle)
        #expect(try await vm.storage.loadMeetingMetadata()[groupID]?.title == renamedTitle)
    }

    @Test("a multi-session meeting refresh publishes one article snapshot")
    func meetingRefreshPublishesOneSnapshot() async throws {
        let priorGroups = UserDefaults.standard.stringArray(forKey: "userMeetingGroupNames")
        defer {
            if let priorGroups {
                UserDefaults.standard.set(priorGroups, forKey: "userMeetingGroupNames")
            } else {
                UserDefaults.standard.removeObject(forKey: "userMeetingGroupNames")
            }
        }

        let vm = makeViewModel()
        let groupID = "stable-group"
        vm.meetingMetadata = [groupID: MeetingMetadata(title: "Weekly Meetings")]

        let sessions = ["Session One", "Session Two"]
        vm.articles = sessions.map { session in
            StudioArticle(
                url: "meeting://\(groupID)/\(StudioViewModel.percentEncodedMeetingPathComponent(session))",
                title: session,
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings,
                parentGroup: groupID
            )
        }
        let artifacts = sessions.enumerated().map { index, session in
            StudioViewModel.ParsedMeetingArtifact(
                url: URL(string: "https://drive.google.com/file/d/transcript-\(index)")!,
                title: "\(session) Transcript",
                sessionKey: session,
                kind: .transcript,
                text: "Speaker: Material for \(session).",
                externalURL: nil,
                localFilePath: nil,
                mimeType: "text/plain",
                modifiedAt: nil
            )
        }

        let revisionBeforeRefresh = vm.articlesRevision
        try await vm.importMeetingArtifacts(
            artifacts,
            groupTitle: "Weekly Meetings",
            driveFolderURL: nil,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No meetings",
            silent: true
        )

        #expect(vm.articlesRevision == revisionBeforeRefresh + 1)

        let revisionBeforeNoOpRefresh = vm.articlesRevision
        try await vm.importMeetingArtifacts(
            artifacts,
            groupTitle: "Weekly Meetings",
            driveFolderURL: nil,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No meetings",
            silent: true
        )

        #expect(vm.articlesRevision == revisionBeforeNoOpRefresh)
    }

    @Test("merging meeting groups moves the row and routes later Read AI sessions")
    func meetingMergeRoutesFutureReadAISessions() async throws {
        let priorGroups = UserDefaults.standard.stringArray(forKey: "userMeetingGroupNames")
        defer {
            if let priorGroups {
                UserDefaults.standard.set(priorGroups, forKey: "userMeetingGroupNames")
            } else {
                UserDefaults.standard.removeObject(forKey: "userMeetingGroupNames")
            }
        }

        let vm = makeViewModel()
        let readAIGroup = "read-ai-weekly"
        let destination = "weekly"
        vm.meetingMetadata = [
            readAIGroup: MeetingMetadata(title: "Weekly Sync from Read AI"),
            destination: MeetingMetadata(title: "Weekly Sync"),
        ]
        try await vm.storage.saveMeetingGroup(
            name: readAIGroup,
            metadata: vm.meetingMetadata[readAIGroup]!
        )
        try await vm.storage.saveMeetingGroup(
            name: destination,
            metadata: vm.meetingMetadata[destination]!
        )
        var existing = StudioArticle(
            url: "meeting://\(readAIGroup)/old-session",
            title: "Old session",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: readAIGroup
        )
        existing.content = "# Old session\n\n## Transcript\n\nOld material"
        existing.state = .ready
        try await vm.storage.saveSource(existing)
        vm.articles = [existing]

        await vm.mergeMeetingGroup(readAIGroup, into: destination)

        #expect(vm.visibleMeetingGroupNames == [destination])
        #expect(vm.articles.first?.parentGroup == destination)
        #expect(vm.meetingMetadata[readAIGroup]?.mergedIntoGroupID == destination)

        // Both the app importer and the Read AI MCP importer resolve this old
        // title before constructing the next session's stable meeting URL.
        #expect(vm.existingMeetingID(forTitle: "Weekly Sync from Read AI") == destination)
    }

    @Test("a background folder refresh cannot bring back a session the learner removed")
    func removedSessionStaysRemovedAcrossFolderRefresh() async throws {
        let vm = makeViewModel()
        let groupID = "acme-nexus"
        let folderURL = "https://drive.google.com/drive/folders/folder-acme"
        let metadata = MeetingMetadata(title: "Acme Lab Nexus", driveFolderURL: folderURL)
        vm.meetingMetadata = [groupID: metadata]
        try await vm.storage.saveMeetingGroup(name: groupID, metadata: metadata)
        let sessionKey = "2026/08/30"
        let notes = StudioViewModel.ParsedMeetingArtifact(
            url: URL(string: "https://drive.google.com/file/d/notes-0830")!,
            title: "2026-08-30 - [Notes] - Journal Club",
            sessionKey: sessionKey,
            kind: .notes,
            text: "* Somatic mutations in Hashimoto's thyroiditis, discussed.",
            externalURL: nil,
            localFilePath: nil,
            mimeType: nil,
            modifiedAt: nil
        )
        let sessionURL = "meeting://\(groupID)/\(StudioViewModel.percentEncodedMeetingPathComponent(sessionKey))"
        func refresh(silent: Bool) async throws {
            try await vm.importMeetingArtifacts(
                [notes],
                groupTitle: "Acme Lab Nexus",
                driveFolderURL: folderURL,
                localFolderPath: nil,
                discoveryOrigin: .googleDriveMeetings,
                emptyMessage: "No supported meeting files found",
                silent: silent
            )
        }

        try await refresh(silent: true)
        let session = try #require(vm.articles.first { $0.url == sessionURL })

        // The learner removes the session. `removeSelected` hides it, then once
        // the Undo window closes dismisses the URL and archives the row, which
        // also drops it from the active rows the view model holds.
        try await vm.storage.dismissSources([session])
        vm.articles.removeAll { $0.id == session.id }
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .archived)

        // The next refresh walks the same folder and finds the same file. It
        // used to see a session the folder had just gained and upsert the
        // archived row back to active.
        try await refresh(silent: true)
        #expect(!vm.articles.contains { $0.url == sessionURL })
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .archived)
        #expect(await vm.storage.isSourceDismissed(url: sessionURL))

        // Choosing the folder again is the learner asking for it back: the
        // tombstone is lifted and the session returns.
        try await refresh(silent: false)
        #expect(vm.articles.contains { $0.url == sessionURL })
        #expect(try await vm.storage.loadPersistedSources(ids: [session.id]).first?.status == .active)
        #expect(!(await vm.storage.isSourceDismissed(url: sessionURL)))
    }

    @Test("a background Drive import cannot resurrect a removed folder under a new title")
    func removedDriveFolderStaysHiddenAcrossProviderRename() async throws {
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
        let groupID = "acme-nexus"
        let folderURL = "https://drive.google.com/drive/folders/folder-acme"
        let metadata = MeetingMetadata(title: "Acme Nexus – Member Drive", driveFolderURL: folderURL)
        vm.meetingMetadata = [groupID: metadata]
        try await vm.storage.saveMeetingGroup(name: groupID, metadata: metadata)
        UserDefaults.standard.set(["google-drive-folder:folder-acme"], forKey: identityKey)
        UserDefaults.standard.set([], forKey: titleKey)

        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "Acme Nexus renamed upstream",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: true
        )

        #expect(vm.meetingMetadata[groupID]?.isHidden == true)
        #expect(try await vm.storage.loadMeetingMetadata()[groupID]?.isHidden == true)

        // Choosing the folder again is explicit restoration and may lift the
        // exact tombstone; only a background/event refresh is forbidden.
        try await vm.importMeetingArtifacts(
            [],
            groupTitle: "Acme Nexus renamed upstream",
            driveFolderURL: folderURL,
            localFolderPath: nil,
            discoveryOrigin: .googleDriveMeetings,
            emptyMessage: "No supported meeting files found",
            silent: false
        )

        #expect(vm.meetingMetadata[groupID]?.isHidden == false)
        #expect(!StudioViewModel.loadRemovedMeetingGroupIdentities().contains("google-drive-folder:folder-acme"))
    }

    @Test("a plugin tab is not pinned back by content the plugin pushed")
    func pluginTabStaysUnpinnedOnSourceArrival() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = [.meetings, .xPosts]
        vm.autoUnpinnedIntegrationTabs = [.meetings, .xPosts]

        vm.articles = [
            StudioArticle(
                url: "https://app.read.ai/analytics/meetings/abc",
                title: "Standup",
                sourceType: .meeting,
                discoveryOrigin: .readAI
            )
        ]

        // A Read AI meeting arriving is the plugin's doing, not a request for
        // the tab. Pinning on arrival is what put Read AI back on the tab bar
        // after every rebuild.
        //
        // Nothing about a Read AI meeting speaks for X, so X stays off the tab
        // bar either way. That half is machine-independent.
        #expect(!vm.visibleTabs.contains(.xPosts))
        #expect(vm.autoUnpinnedIntegrationTabs.contains(.xPosts))

        // Meetings is not plugin-backed as a whole: being signed into Google
        // Drive pins it on its own, correctly and regardless of this article. So
        // the end-to-end assertion is only meaningful on a machine with no Drive
        // account attached — `sourceArrivalPinsTabIgnoresPluginPushes` covers
        // the rule itself with no such dependency.
        if !GoogleDriveService.shared.isSignedIn {
            #expect(!vm.visibleTabs.contains(.meetings))
            #expect(vm.autoUnpinnedIntegrationTabs.contains(.meetings))
        }
    }

    @Test("a source only pins its tab when its arrival is the learner's own doing")
    func sourceArrivalPinsTabIgnoresPluginPushes() {
        // Read AI pushes meetings in; Drive sync and folder imports are asked
        // for. One tab now covers all three, so the rule reads the session's
        // provider rather than the tab's classification.
        #expect(!StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .readAI))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .googleDriveMeetings))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .localMeetings))
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: nil))
        // A pasted Zoom link is the learner's own doing too, so it pins.
        #expect(StudioViewModel.sourceArrivalPinsTab(.meetings, discoveryOrigin: .zoom))
        // Everything else pins on its first source.
        #expect(StudioViewModel.sourceArrivalPinsTab(.papers, discoveryOrigin: .localPapers))
        #expect(StudioViewModel.sourceArrivalPinsTab(.xPosts, discoveryOrigin: .xBookmarks))
    }

    @Test("a non-plugin integration tab is pinned back once its first source arrives")
    func integrationTabPinsOnFirstSource() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = [.meetings, .xPosts]
        vm.autoUnpinnedIntegrationTabs = [.meetings, .xPosts]

        vm.articles = [
            StudioArticle(
                url: "https://drive.google.com/file/d/abc",
                title: "Weekly sync",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings
            )
        ]

        #expect(vm.visibleTabs.contains(.meetings))
        // Nothing points at X being in use, so it stays off the tab bar.
        #expect(!vm.visibleTabs.contains(.xPosts))
        #expect(!vm.autoUnpinnedIntegrationTabs.contains(.meetings))
    }

    @Test("a tab the learner unpinned is not pinned back by its own sources")
    func userUnpinnedIntegrationTabStaysUnpinned() {
        let vm = makeViewModel()
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
        }
        vm.hiddenTabs = []
        vm.autoUnpinnedIntegrationTabs = [.meetings]
        // Unpinning by hand drops Studio's claim over the tab, even though the
        // tab was unpinned by default earlier.
        vm.hideTab(.meetings)
        #expect(!vm.autoUnpinnedIntegrationTabs.contains(.meetings))

        vm.articles = [
            StudioArticle(
                url: "https://drive.google.com/file/d/def",
                title: "Retro",
                sourceType: .meeting,
                discoveryOrigin: .googleDriveMeetings
            )
        ]

        #expect(!vm.visibleTabs.contains(.meetings))
    }

    @Test("a recorded integration unpin never re-applies over a stored pin choice")
    func integrationUnpinDefaultsRespectStoredChoice() {
        let vm = makeViewModel()
        let appliedKey = StudioSidebarTab.integrationUnpinAppliedPreferenceKey
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        let savedApplied = UserDefaults.standard.stringArray(forKey: appliedKey)
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
            if let savedApplied {
                PreferenceStore.set(savedApplied, forKey: appliedKey)
            } else {
                PreferenceStore.remove(forKey: appliedKey)
            }
        }
        // The shape a rebuild produces once the marker is durable: hydration has
        // restored both the applied marker and the pin state the learner chose —
        // Meetings pinned by hand, X unpinned by hand.
        PreferenceStore.set(
            StudioSidebarTab.allCases.filter(\.requiresIntegrationSetup).map(\.rawValue).sorted(),
            forKey: appliedKey
        )
        vm.hiddenTabs = [.xPosts]
        vm.autoUnpinnedIntegrationTabs = []

        vm.applyIntegrationTabUnpinDefaults()

        // A tab the learner pinned stays pinned...
        #expect(!vm.hiddenTabs.contains(.meetings))
        // ...and one they unpinned is not handed back to Studio to pin later.
        #expect(vm.hiddenTabs.contains(.xPosts))
        #expect(vm.autoUnpinnedIntegrationTabs.isEmpty)
    }

    @Test("an unrecorded integration unpin hides the plugin tabs once")
    func integrationUnpinDefaultsApplyOnce() {
        let vm = makeViewModel()
        let appliedKey = StudioSidebarTab.integrationUnpinAppliedPreferenceKey
        let savedHidden = vm.hiddenTabs
        let savedAuto = vm.autoUnpinnedIntegrationTabs
        let savedApplied = UserDefaults.standard.stringArray(forKey: appliedKey)
        defer {
            vm.hiddenTabs = savedHidden
            vm.autoUnpinnedIntegrationTabs = savedAuto
            if let savedApplied {
                PreferenceStore.set(savedApplied, forKey: appliedKey)
            } else {
                PreferenceStore.remove(forKey: appliedKey)
            }
        }
        PreferenceStore.set([String](), forKey: appliedKey)
        vm.hiddenTabs = []
        vm.autoUnpinnedIntegrationTabs = []

        vm.applyIntegrationTabUnpinDefaults()

        #expect(vm.hiddenTabs.contains(.meetings))
        #expect(vm.hiddenTabs.contains(.xPosts))
        // Recorded, so the next launch — or the next rebuild, now that the marker
        // is on the sync rail — leaves the learner's pins alone.
        let applied = Set(UserDefaults.standard.stringArray(forKey: appliedKey) ?? [])
        for tab in StudioSidebarTab.allCases where tab.requiresIntegrationSetup {
            #expect(applied.contains(tab.rawValue))
        }
        #expect(StudioViewModel.integrationTabUnpinState().pending.isEmpty)
    }

    @Test("reorderTab no-op for same source and destination")
    func reorderTabSamePosition() {
        let vm = makeViewModel()
        let original = Array(vm.tabOrder)
        vm.reorderTab(from: .articles, to: .articles)
        #expect(vm.tabOrder == original)
    }

    @Test("showMore increments displayLimit by 40")
    func showMoreIncrements() {
        let vm = makeViewModel()
        vm.displayLimit = 40
        vm.showMore()
        #expect(vm.displayLimit == 80)
        vm.showMore()
        #expect(vm.displayLimit == 120)
    }

    @Test("visibleTabs filters out hiddenTabs")
    func visibleTabsFilters() {
        let vm = makeViewModel()
        vm.tabOrder = [.articles, .papers, .books, .podcasts, .videos]
        vm.hiddenTabs = [.books, .videos]
        let visible = vm.visibleTabs
        #expect(!visible.contains(.books))
        #expect(!visible.contains(.videos))
        #expect(visible.contains(.articles))
        #expect(visible.contains(.papers))
    }

    @Test("visibleTabs respects tabOrder")
    func visibleTabsOrder() {
        let vm = makeViewModel()
        vm.tabOrder = [.podcasts, .books, .articles]
        vm.hiddenTabs = []
        let visible = vm.visibleTabs
        // The three keep the specified order (Meetings, which the order does
        // not name, slots in after Books).
        #expect(visible.filter { [.podcasts, .books, .articles].contains($0) } == [.podcasts, .books, .articles])
        #expect(visible.first == .podcasts)
    }
}
