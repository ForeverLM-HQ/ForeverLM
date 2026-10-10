import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// Screen record mode (`ScreenRecordMode`, `ScreenRecordScope`): the admin-only
/// filming scope. The gate, the cutoff, the predicates every list asks, and
/// the admin-only MCP entries. Each test binds a throwaway defaults suite of
/// its own, so turning the mode on here narrows nothing for a neighbour.
@Suite("Screen record mode", .serialized)
@MainActor
struct ScreenRecordModeTests {

    static let keys = [
        ScreenRecordMode.enabledKey,
        ScreenRecordMode.notebookIDKey,
        ScreenRecordMode.cutoffKey,
        ScreenRecordMode.confirmedAdminKey,
        ScreenRecordMode.librarySourcesKey,
        ScreenRecordMode.imageIDsKey,
        ScreenRecordMode.meetingGroupIDsKey,
    ]

    /// Runs `body` against a throwaway defaults suite bound for this task only
    /// (`ScreenRecordMode.overrideDefaults`): the real switch lives in
    /// `UserDefaults.standard`, which parallel tests and the Dev build share.
    private func withCleanDefaults(_ body: () async throws -> Void) async throws {
        let suiteName = "ScreenRecordModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MCPError.invalidInput("Could not open a defaults suite for the test.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await ScreenRecordMode.$overrideDefaults.withValue(ScreenRecordMode.DefaultsOverride(defaults: defaults)) {
            try await body()
        }
    }

    private func payload(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    @Test("A learner the proxy does not call admin: the switch does nothing, and MCP does not know the setting")
    func nonAdminIsOffAndUnlisted() async throws {
        try await withCleanDefaults {
            ScreenRecordMode.setEnabled(true)
            ScreenRecordMode.setNotebookID("notebook")
            #expect(ScreenRecordMode.isStoredOn)
            #expect(!ScreenRecordMode.isAvailable)
            if !ScreenRecordMode.isForcedByBuild {
                #expect(!ScreenRecordMode.isEffective)
                #expect(ScreenRecordMode.cutoff == nil)
                #expect(ScreenRecordScope.resolve { _ in ["source"] } == nil)
            }

            let ids = MCPDataStore.appSettingsCatalog().map(\.id)
            #expect(!ids.contains("recording.screen_record_mode"))
            #expect(!ids.contains("recording.notebook_id"))

            let store = MCPDataStore()
            // An ordinary unknown-setting refusal, the same as for any id.
            await #expect(throws: MCPError.self) {
                _ = try await store.setAppSetting(settingID: "recording.screen_record_mode", value: false)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.getAppSettings(pane: nil, settingID: "recording.notebook_id")
            }
            let all = try payload(try await store.getAppSettings(pane: nil, settingID: nil))
            let listed = (all["settings"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(!listed.contains { $0.hasPrefix("recording.") })
        }
    }

    @Test("The admin: effective, both entries listed, and set_app_setting turns the mode on end to end")
    func adminCanTurnItOnOverMCP() async throws {
        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            #expect(ScreenRecordMode.isAvailable)
            #expect(!ScreenRecordMode.isEffective || ScreenRecordMode.isForcedByBuild)

            let ids = MCPDataStore.appSettingsCatalog().map(\.id)
            #expect(ids.contains("recording.screen_record_mode"))
            #expect(ids.contains("recording.notebook_id"))

            let store = MCPDataStore()
            let row = try payload(try await store.setAppSetting(settingID: "recording.screen_record_mode", value: true))
            #expect(row["value"] as? Bool == true)
            #expect(row["changed"] as? Bool == true)
            #expect(ScreenRecordMode.isEffective)
            #expect(ScreenRecordMode.cutoff != nil)

            // "none" clears the Notebook; the scope then shows only new work.
            _ = try await store.setAppSetting(settingID: "recording.notebook_id", value: "none")
            #expect(ScreenRecordMode.notebookID == nil)
            let scope = try #require(ScreenRecordScope.resolve { _ in ["ignored"] })
            #expect(scope.notebookID == nil)
            #expect(scope.allowedSourceIDs.isEmpty)

            _ = try await store.setAppSetting(settingID: "recording.screen_record_mode", value: false)
            #expect(!ScreenRecordMode.isStoredOn)
            #expect(ScreenRecordMode.overrideDefaults?.defaults.object(forKey: ScreenRecordMode.cutoffKey) == nil)
        }
    }

    @Test("Turning the mode on stamps the cutoff once; turning it on again keeps it")
    func cutoffIsStampedOnce() async throws {
        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
            ScreenRecordMode.setEnabled(true, now: first)
            ScreenRecordMode.setEnabled(true, now: first.addingTimeInterval(3_600))
            #expect(ScreenRecordMode.cutoff == first)
            ScreenRecordMode.setEnabled(false)
            ScreenRecordMode.setEnabled(true, now: first.addingTimeInterval(7_200))
            #expect(ScreenRecordMode.cutoff == first.addingTimeInterval(7_200))
        }
    }

    @Test("Sign-out clears the admin answer, so the next account starts with the mode off")
    func signOutClearsTheAdminAnswer() async throws {
        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true)
            #expect(ScreenRecordMode.isEffective)
            ScreenRecordMode.clearAdminStatus()
            #expect(!ScreenRecordMode.isAvailable)
            #expect(ScreenRecordMode.isEffective == ScreenRecordMode.isForcedByBuild)
        }
    }

    @Test("The keys are device-local: none of them syncs")
    func keysNeverSync() {
        for key in Self.keys {
            #expect(!SyncedPreferenceKeys.isSynced(key), "\(key) would reach the learner's other devices")
        }
    }

    @Test("The scope's predicates: Notebook sources and new work show, everything else does not")
    func predicates() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let after = cutoff.addingTimeInterval(60)
        let scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)

        #expect(scope.allowsSource(id: "filmed", addedAt: before))
        #expect(scope.allowsSource(id: "new", addedAt: after))
        #expect(scope.allowsSource(id: "at-cutoff", addedAt: cutoff))
        #expect(!scope.allowsSource(id: "private", addedAt: before))

        #expect(scope.allowsNotebook(id: "notebook", createdAt: before))
        #expect(scope.allowsNotebook(id: "new-notebook", createdAt: after))
        #expect(!scope.allowsNotebook(id: "private-notebook", createdAt: before))

        #expect(scope.allowsItem(createdAt: after))
        #expect(scope.allowsItem(createdAt: before, notebookIDs: ["notebook"]))
        #expect(scope.allowsItem(createdAt: before, notebookIDs: [nil, "notebook"]))
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: ["private-notebook"]))
        #expect(!scope.allowsItem(createdAt: nil))

        // A walkthrough rides its source; the learner's own chat about the
        // same filmed source does not (it is filed nowhere, made before).
        #expect(scope.allowsSourceDerived(createdAt: before, sourceID: "filmed"))
        #expect(scope.allowsSourceDerived(createdAt: after, sourceID: "private"))
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "private"))

        let noNotebook = ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: cutoff)
        #expect(!noNotebook.allowsItem(createdAt: before, notebookIDs: [nil]))
    }

    @Test("Library sources: public papers, podcasts, books and public videos show; meetings, X posts, uploads and private hosts never do")
    func librarySourcesArePublicOnly() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let narrow = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)
        var wide = narrow
        wide.showsLibrarySources = true

        let paper = ("paper", "https://doi.org/10.1038/example")
        #expect(!narrow.allowsSource(id: "p", addedAt: before, kind: paper.0, url: paper.1))
        #expect(wide.allowsSource(id: "p", addedAt: before, kind: paper.0, url: paper.1))
        #expect(wide.allowsSource(id: "pod", addedAt: before, kind: "podcast", url: "https://feeds.example.org/ep1"))
        #expect(wide.allowsSource(id: "yt", addedAt: before, kind: "video", url: "https://www.youtube.com/watch?v=abc"))
        #expect(wide.allowsSource(id: "book", addedAt: before, kind: "book", url: "/Users/someone/Books/We Are Electric.epub"))

        // Never public, whatever the switch says.
        #expect(!wide.allowsSource(id: "m", addedAt: before, kind: "meeting", url: "https://example.org/meeting"))
        #expect(!wide.allowsSource(id: "x", addedAt: before, kind: "xPost", url: "https://x.com/someone/status/1"))
        // A paid subscriber feed names its subscriber; its episodes link to the public page.
        #expect(!wide.allowsSource(
            id: "feed", addedAt: before, kind: "podcast", url: "https://peterattiamd.com/guest/",
            show: "The Peter Attia Drive - Private Subscriber Feed (🔓 for Someone)"
        ))
        #expect(wide.allowsSource(
            id: "members", addedAt: before, kind: "podcast", url: "https://example.org/ep2",
            show: "Members of Technical Staff"
        ))
        #expect(!wide.allowsSource(id: "zoom", addedAt: before, kind: "video", url: "https://us02web.zoom.us/rec/share/abc"))
        #expect(!wide.allowsSource(id: "vid", addedAt: before, kind: "video", url: "https://app.read.ai/analytics/meetings/1"))
        #expect(!wide.allowsSource(id: "upload", addedAt: before, kind: "paper", url: "file:///Users/someone/private.pdf"))
        #expect(!wide.allowsSource(id: "pasted", addedAt: before, kind: "article", url: nil))
        #expect(!wide.allowsSource(id: "drive", addedAt: before, kind: "article", url: "https://docs.google.com/document/d/1"))
        #expect(!wide.allowsSource(id: "unknown", addedAt: before, kind: nil, url: paper.1))

        // The switch widens sources only: the learner's own work is unchanged.
        #expect(!wide.allowsItem(createdAt: before, notebookIDs: ["private-notebook"]))
    }

    @Test("Meetings: only the kept folders' sessions show, library sources or not")
    func keptMeetingFoldersShow() async throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        var scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: [], cutoff: cutoff)
        scope.showsLibrarySources = true
        scope.allowedMeetingGroupIDs = ["zoom:stanford.zoom.us"]
        let url = "https://stanford.zoom.us/rec/share/abc"
        #expect(scope.allowsSource(id: "seminar", addedAt: before, kind: "meeting", url: url, group: "zoom:stanford.zoom.us"))
        #expect(!scope.allowsSource(id: "standup", addedAt: before, kind: "meeting", url: url, group: "zoom:other.zoom.us"))
        #expect(!scope.allowsSource(id: "loose", addedAt: before, kind: "meeting", url: url, group: nil))
        // The list names meeting folders only: a paper in a folder of that id earns nothing by it.
        #expect(!scope.allowsSource(id: "paper", addedAt: before, kind: "paper", url: nil, group: "zoom:stanford.zoom.us"))

        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            _ = try await MCPDataStore().setAppSetting(settingID: "recording.meeting_group_ids", value: ["zoom:stanford.zoom.us"])
            #expect(ScreenRecordMode.meetingGroupIDs == ["zoom:stanford.zoom.us"])
            #expect(try #require(ScreenRecordScope.resolve { _ in [] }).allowedMeetingGroupIDs == ["zoom:stanford.zoom.us"])
        }
    }

    @Test("Images: the kept list and the take's own pictures show; the rest do not")
    func imagesOnTheListShow() async throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: [], cutoff: cutoff)
        scope.allowedImageIDs = ["kept"]
        #expect(scope.allowsImage(id: "kept", createdAt: cutoff.addingTimeInterval(-3_600)))
        #expect(scope.allowsImage(id: "new", createdAt: cutoff.addingTimeInterval(60)))
        #expect(!scope.allowsImage(id: "old", createdAt: cutoff.addingTimeInterval(-60)))

        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            let store = MCPDataStore()
            _ = try await store.setAppSetting(settingID: "recording.image_ids", value: [" kept ", "kept", "other"])
            _ = try await store.setAppSetting(settingID: "recording.library_sources", value: true)
            #expect(ScreenRecordMode.imageIDs == ["kept", "other"])
            let resolved = try #require(ScreenRecordScope.resolve { _ in [] })
            #expect(resolved.allowedImageIDs == ["kept", "other"])
            #expect(resolved.showsLibrarySources)
        }
    }

    @Test("A day in the Planner while recording: only the take's own blocks and activity show")
    func dayPlanIsScoped() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let after = cutoff.addingTimeInterval(60)
        let scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)
        let day = "2026-09-24"
        func block(_ id: String, createdAt: Date, notebook: String? = nil, sources: [String] = [], calendar: String? = nil) -> TimeBlock {
            TimeBlock(
                id: id, dayPlanID: day, startMinute: 540, endMinute: 600, title: id,
                notebookID: notebook, sourceIDs: sources, calendarEventID: calendar,
                createdAt: createdAt, updatedAt: createdAt
            )
        }
        let detail = DayPlanDetail(
            plan: DayPlan(date: day),
            blocks: [
                block("private", createdAt: before),
                block("notebook", createdAt: before, notebook: "notebook"),
                block("filmed-source", createdAt: before, sources: ["filmed"]),
                block("drawn-in-take", createdAt: after),
                block("drawn-in-take-filmed", createdAt: after, sources: ["filmed"]),
                block("app-drawn-private", createdAt: after, sources: ["filmed", "private"]),
                block("calendar-event", createdAt: after, calendar: "event-1"),
            ],
            activities: [
                DayActivity(id: "a1", dayPlanID: day, startMinute: 500, endMinute: 520, kind: .reading, targetID: "private", title: "Private", createdAt: before, updatedAt: before),
                DayActivity(id: "a2", dayPlanID: day, startMinute: 520, endMinute: 530, kind: .reading, targetID: "filmed", title: "Filmed", createdAt: before, updatedAt: before),
                DayActivity(id: "a3", dayPlanID: day, startMinute: 530, endMinute: 540, kind: .reading, targetID: "filmed", title: "On camera", createdAt: after, updatedAt: after),
                DayActivity(id: "a4", dayPlanID: day, startMinute: 540, endMinute: 550, kind: .reading, targetID: "private", title: "Other window", createdAt: after, updatedAt: after),
                DayActivity(id: "a5", dayPlanID: day, startMinute: 550, endMinute: 560, kind: .chat, targetID: "chat-1", title: "Asked on camera", createdAt: after, updatedAt: after),
            ]
        )
        let scoped = scope.scoped(detail)
        #expect(scoped.blocks.map(\.id) == ["drawn-in-take", "drawn-in-take-filmed"])
        #expect(scoped.activities.map(\.id) == ["a3", "a5"])
        #expect(detail.blocks.count == 7, "the stored day is untouched")
    }

    @Test("list_courses and the app's Courses list ask one course rule")
    func listCoursesAsksTheCourseRule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordModeTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let ks = try store.knowledgeStore()
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-3_600)

        try ScreenRecordCourseFixtures.saveCourse(ks, "filmed-lessons")
        try ScreenRecordCourseFixtures.saveSource(ks, "filmed-lesson", .course, addedAt: before, course: "filmed-lessons")
        try ScreenRecordCourseFixtures.saveCourse(ks, "private-lessons")
        try ScreenRecordCourseFixtures.saveSource(ks, "private-lesson", .course, addedAt: before, course: "private-lessons")
        try ScreenRecordCourseFixtures.saveSource(
            ks, "private-video", .video, url: "https://www.youtube.com/watch?v=private", addedAt: before
        )
        try ScreenRecordCourseFixtures.saveCourse(ks, "followed", items: ["private-video"])
        let recording = try ks.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["filmed-lesson"]
        )
        _ = try ks.linkCourseToNotebook(goalID: recording.id, courseID: "followed", sourceIDs: [])

        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            ScreenRecordMode.setNotebookID(recording.id)

            let listed = try store.listCourses()
            #expect(listed.contains("id: filmed-lessons"), "a lesson of the recording Notebook")
            #expect(listed.contains("id: followed"), "followed by the recording Notebook, though no lesson is filmed")
            #expect(!listed.contains("id: private-lessons"))
            let shown = try ks.screenRecordShownCourseIDs(scope: try #require(ks.screenRecordScope()))
            #expect(shown == ["filmed-lessons", "followed"])
        }
    }
}

/// Courses and their sources as the course tests below seed them.
enum ScreenRecordCourseFixtures {
    /// A source of `type`, ready to read, added at `addedAt`; `course` makes
    /// it a lesson of that course when it is course-typed.
    static func saveSource(
        _ store: KnowledgeStore,
        _ id: String,
        _ type: StudioSourceType,
        url: String? = nil,
        addedAt: Date,
        course: String? = nil
    ) throws {
        var source = StudioArticle(
            url: url ?? "https://school.example.org/\(id)", title: id, sourceType: type, parentGroup: course, id: id
        )
        source.content = "Readable text for \(id)."
        source.state = .ready
        source.dateAdded = addedAt
        try store.saveSource(source)
    }

    /// A course, with one lecture holding `items` as videos when it has any.
    static func saveCourse(_ store: KnowledgeStore, _ id: String, items: [String] = []) throws {
        try store.saveCourseGroup(name: id, metadata: CourseMetadata(title: id))
        guard !items.isEmpty else { return }
        let lecture = CourseSession(id: "\(id)-lecture", courseName: id, number: 1)
        try store.saveCourseOutline(
            courseName: id,
            lectures: [lecture],
            items: items.enumerated().map { index, sourceID in
                CourseLectureItem(id: "\(id)-item-\(index)", lectureId: lecture.id, sourceId: sourceID, role: .video, sortIndex: index)
            }
        )
    }
}

/// The counts the 0.112.0 docs screenshot caught coming from the real
/// library under a `RECORDING_PRIVACY` build with no recording Notebook: the
/// Sources list's hidden-items footer ("4 hidden articles"), the Papers tab's
/// badge, and the Notebooks home's "4 courses aren't in a notebook". Each
/// counts only what the scope lets on screen; the source arrays stay whole.
@Suite("Screen record mode's counts")
@MainActor
struct ScreenRecordCountsTests {
    private let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var before: Date { cutoff.addingTimeInterval(-3_600) }
    private var after: Date { cutoff.addingTimeInterval(60) }

    /// The recording Notebook's scope: its sources, and what the take adds.
    private func filming(_ sourceIDs: Set<String>) -> ScreenRecordScope {
        ScreenRecordScope(notebookID: "recording", allowedSourceIDs: sourceIDs, cutoff: cutoff)
    }

    /// The docs screenshot's: no recording Notebook, and nothing added since
    /// the build launched.
    private var noNotebook: ScreenRecordScope {
        ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: after.addingTimeInterval(3_600))
    }

    /// A view model on an empty store of its own, with the mode off whatever
    /// the host's settings say.
    private func makeViewModel() -> (StudioViewModel, StorageService) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordCountsTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        vm.screenRecordScope = nil
        return (vm, storage)
    }

    private func source(
        _ id: String, _ type: StudioSourceType, addedAt: Date, hidden: Bool = false, group: String? = nil, show: String? = nil
    ) -> StudioArticle {
        var article = StudioArticle(url: "https://example.org/\(id)", title: id, sourceType: type, parentGroup: group, id: id)
        article.dateAdded = addedAt
        article.isHidden = hidden
        if let show { article.domain = show }
        return article
    }

    private func footer(_ tab: StudioSidebarTab, _ vm: StudioViewModel) -> [Int] {
        let counts = HiddenItemsModel.footerCounts(for: tab, vm: vm)
        return [counts.groups, counts.items]
    }

    @Test("The hidden-items footer names only hidden sources the take may show, and groups holding one")
    func hiddenItemsFooter() {
        let (vm, _) = makeViewModel()
        vm.articles = [
            source("filmed", .article, addedAt: before, hidden: true),
            source("added-on-camera", .article, addedAt: after, hidden: true),
            source("private-1", .article, addedAt: before, hidden: true),
            source("private-2", .article, addedAt: before, hidden: true),
            source("on-screen", .article, addedAt: before),
            source("filmed-session", .meeting, addedAt: before, group: "zoom:filmed"),
            source("private-session", .meeting, addedAt: before, group: "zoom:private"),
            source("filmed-episode", .podcast, addedAt: before, show: "Filmed Show"),
            source("private-episode", .podcast, addedAt: before, show: "Private Show"),
            source("mixed-filmed", .podcast, addedAt: before, show: "Mixed Show"),
            source("mixed-private", .podcast, addedAt: before, show: "Mixed Show"),
        ]
        vm.meetingMetadata = [
            "zoom:filmed": MeetingMetadata(title: "Filmed seminar", isHidden: true),
            "zoom:private": MeetingMetadata(title: "Private standup", isHidden: true),
        ]
        vm.hiddenPodcastShows = ["Filmed Show", "Private Show"]
        vm.hiddenPodcastEpisodeIDs = ["mixed-filmed", "mixed-private"]

        // Off (every learner but the admin): the whole library's.
        #expect(footer(.articles, vm) == [0, 4])
        #expect(footer(.meetings, vm) == [2, 0])

        vm.screenRecordScope = filming(["filmed", "filmed-session", "filmed-episode", "mixed-filmed"])
        #expect(footer(.articles, vm) == [0, 2])
        #expect(Set(HiddenItemsModel.build(for: .articles, vm: vm).items.map(\.id)) == ["filmed", "added-on-camera"])
        // A hidden folder or show is named only while it holds a source on
        // screen: its name is the learner's own. A show this Mac blocks holds
        // none of these, so it is never named either.
        #expect(footer(.meetings, vm) == [1, 0])
        #expect(HiddenItemsModel.build(for: .meetings, vm: vm).groups.map(\.id) == ["zoom:filmed"])
        #expect(footer(.podcasts, vm) == [1, 1])
        let shows = HiddenItemsModel.build(for: .podcasts, vm: vm).groups
        #expect(shows.map(\.id) == ["Filmed Show", "Mixed Show"])
        #expect(shows.first { $0.id == "Mixed Show" }?.hiddenEpisodes.map(\.id) == ["mixed-filmed"])

        // The docs screenshot: nothing is named, so the footer draws no row.
        vm.screenRecordScope = noNotebook
        #expect(footer(.articles, vm) == [0, 0])
        #expect(footer(.meetings, vm) == [0, 0])
        #expect(footer(.podcasts, vm) == [0, 0])
        #expect(HiddenItemsModel.build(for: .articles, vm: vm).isEmpty)
        #expect(vm.articles.count == 11, "the source array stays whole")
    }

    @Test("The Papers tab's badge counts only the papers the take may show")
    func papersBadge() async {
        let (vm, _) = makeViewModel()
        vm.articles = [
            source("filmed-paper", .paper, addedAt: before),
            source("paper-added-on-camera", .paper, addedAt: after),
            source("private-paper", .paper, addedAt: before),
        ]
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 3)

        vm.screenRecordScope = filming(["filmed-paper"])
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 2)

        vm.screenRecordScope = noNotebook
        await vm.refreshPapersWithoutPDFBadgeNow()
        #expect(vm.papersWithoutPDFBadgeCount == 0)
        #expect(vm.articles.count == 3)
    }

    @Test("A course shows while recording when the recording Notebook follows it or one of its lessons is on screen")
    func courseShownByFollowOrLesson() throws {
        let store = try KnowledgeStore(inMemory: true)
        typealias F = ScreenRecordCourseFixtures
        try F.saveCourse(store, "filmed-lessons")
        try F.saveSource(store, "filmed-lesson", .course, addedAt: before, course: "filmed-lessons")
        try F.saveCourse(store, "made-on-camera")
        try F.saveSource(
            store, "new-lesson", .course,
            url: GeneratedCourseLesson.url(courseID: "made-on-camera", module: 1, kind: .lesson),
            addedAt: after, course: "made-on-camera"
        )
        try F.saveCourse(store, "public-lessons")
        try F.saveSource(store, "public-lesson", .course, addedAt: before, course: "public-lessons")
        try F.saveCourse(store, "generated-earlier")
        try F.saveSource(
            store, "generated-lesson", .course,
            url: GeneratedCourseLesson.url(courseID: "generated-earlier", module: 1, kind: .lesson),
            addedAt: before, course: "generated-earlier"
        )
        try F.saveSource(store, "filmed-video", .video, url: "https://www.youtube.com/watch?v=filmed", addedAt: before)
        try F.saveCourse(store, "cites-filmed", items: ["filmed-video"])
        try F.saveSource(store, "private-video", .video, url: "https://www.youtube.com/watch?v=private", addedAt: before)
        try F.saveCourse(store, "followed", items: ["private-video"])
        let recording = try store.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["filmed-lesson", "filmed-video"]
        )
        _ = try store.linkCourseToNotebook(goalID: recording.id, courseID: "followed", sourceIDs: [])

        // A lecture citing a filmed video earns its course nothing; the
        // course the recording Notebook follows shows.
        let scope = ScreenRecordScope(notebookID: recording.id, allowedSourceIDs: ["filmed-lesson", "filmed-video"], cutoff: cutoff)
        #expect(try store.screenRecordShownCourseIDs(scope: scope) == ["filmed-lessons", "made-on-camera", "followed"])

        // Library sources add the courses whose lessons are public; a
        // generated course's lessons never are.
        var wide = scope
        wide.showsLibrarySources = true
        #expect(try store.screenRecordShownCourseIDs(scope: wide) == [
            "filmed-lessons", "made-on-camera", "followed", "public-lessons",
        ])

        // The docs screenshot: no course.
        #expect(try store.screenRecordShownCourseIDs(scope: noNotebook).isEmpty)
    }

    @Test("A course followed by another Notebook stays hidden while recording")
    func shownCourses() throws {
        let store = try KnowledgeStore(inMemory: true)
        typealias F = ScreenRecordCourseFixtures
        try F.saveCourse(store, "filmed-lessons")
        try F.saveSource(store, "filmed-lesson", .course, addedAt: before, course: "filmed-lessons")
        try F.saveCourse(store, "followed")
        try F.saveCourse(store, "followed-elsewhere")
        try F.saveCourse(store, "private")
        let recording = try store.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["filmed-lesson"]
        )
        let other = try store.createCompanionGoal(
            title: "Other Notebook", topic: "other", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        _ = try store.linkCourseToNotebook(goalID: other.id, courseID: "followed-elsewhere", sourceIDs: [])
        _ = try store.linkCourseToNotebook(goalID: recording.id, courseID: "followed", sourceIDs: [])

        let scope = ScreenRecordScope(notebookID: recording.id, allowedSourceIDs: ["filmed-lesson"], cutoff: cutoff)
        #expect(try store.screenRecordShownCourseIDs(scope: scope) == ["filmed-lessons", "followed"])
        #expect(try store.screenRecordShownCourseIDs(scope: noNotebook).isEmpty)
    }

    @Test("The Courses list, its search and its chip name only the courses the take may show")
    func coursesListFollowsTheScope() async throws {
        let (vm, storage) = makeViewModel()
        let store = try await storage.notebookFilesKnowledgeStore()
        typealias F = ScreenRecordCourseFixtures
        try F.saveCourse(store, "filmed-lessons")
        try F.saveSource(store, "filmed-lesson", .course, addedAt: before, course: "filmed-lessons")
        try F.saveCourse(store, "private-course")
        vm.courseMetadata = try await storage.loadCourseMetadata()
        #expect(Set(vm.shownCourseGroupNames) == ["filmed-lessons", "private-course"])

        vm.screenRecordScope = filming(["filmed-lesson"])
        #expect(vm.shownCourseGroupNames.isEmpty, "none until the take's courses are read")
        await vm.loadScreenRecordShownCourses()
        #expect(vm.shownCourseGroupNames == ["filmed-lessons"])
        #expect(vm.courseGroupNames(matching: "") == ["filmed-lessons"])
        #expect(vm.courseGroupNames(matching: "private").isEmpty)
        #expect(Set(vm.visibleCourseGroupNames) == ["filmed-lessons", "private-course"], "the courses in memory stay whole")

        vm.screenRecordScope = noNotebook
        await vm.loadScreenRecordShownCourses()
        #expect(vm.shownCourseGroupNames.isEmpty)

        vm.screenRecordScope = nil
        #expect(vm.screenRecordShownCourseIDs == nil)
        #expect(Set(vm.shownCourseGroupNames) == ["filmed-lessons", "private-course"])
    }
}

#endif

@Suite("Screen record mode hides the account name")
struct ScreenRecordAccountNameTests {
    @Test("While recording, the rail and greeting show the stand-in, never the saved name")
    func recordingShowsTheStandIn() {
        let shown = MacAccountUser.displayedFullName(saved: "Ada Lovelace", recording: true)
        #expect(shown == MacAccountUser.recordingStandInName)
        #expect(MacAccountUser.leadingName(of: shown) == "Learner")
        #expect(MacAccountUser.monogram(of: shown) == "L")
        // Off the take, the saved name is what shows.
        #expect(MacAccountUser.displayedFullName(saved: "Ada Lovelace", recording: false)
            == MacAccountUser.resolvedFullName(saved: "Ada Lovelace"))
    }
}
