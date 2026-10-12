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
        ScreenRecordMode.sourceIDsKey,
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

    @Test("The scope's predicates: Notebook sources, safe captures and new work show, everything else does not")
    func predicates() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let after = cutoff.addingTimeInterval(60)
        let scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)

        #expect(scope.allowsSource(id: "filmed", addedAt: before))
        #expect(scope.allowsSource(
            id: "new", addedAt: after, kind: "article", url: "https://example.org/bioelectricity",
            origin: .safari
        ))
        #expect(scope.allowsSource(
            id: "at-cutoff", addedAt: cutoff, kind: "xPost", url: "https://x.com/example/status/123",
            origin: .xBookmarks
        ))
        #expect(!scope.allowsSource(id: "new-untyped", addedAt: after))
        #expect(!scope.allowsSource(id: "private", addedAt: before))

        #expect(scope.allowsNotebook(id: "notebook", createdAt: before))
        #expect(scope.allowsNotebook(id: "new-notebook", createdAt: after))
        #expect(!scope.allowsNotebook(id: "private-notebook", createdAt: before))

        #expect(scope.allowsItem(createdAt: after))
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: ["notebook"]))
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: [nil, "notebook"]))
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: ["private-notebook"]))
        #expect(!scope.allowsItem(createdAt: nil))

        // Neither an older walkthrough nor a chat gets a pass from its source.
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "filmed"))
        #expect(scope.allowsSourceDerived(createdAt: after, sourceID: "private"))
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "private"))

        let noNotebook = ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: cutoff)
        #expect(!noNotebook.allowsItem(createdAt: before, notebookIDs: [nil]))
    }

    @Test("Old notebook outputs stay hidden, including undated work; the exact cutoff is included")
    func notebookMembershipNeverExposesOldOutputs() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)
        #expect(!scope.allowsItem(createdAt: nil, notebookIDs: ["notebook"]))
        #expect(!scope.allowsItem(createdAt: before, notebookIDs: ["notebook"]))
        #expect(scope.allowsItem(createdAt: cutoff, notebookIDs: ["notebook"]))
        #expect(scope.allowsSourceDerived(createdAt: cutoff, sourceID: "filmed"))
        #expect(!scope.allowsSourceDerived(createdAt: before, sourceID: "filmed"))
    }

    @Test("A mixed source deck shows only the cards drafted during this take")
    func mixedDraftDeckKeepsOnlyNewCards() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        let scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["filmed"], cutoff: cutoff)
        let cards = [
            Flashcard(id: "old", front: "Old", back: "Old", draftedAt: before),
            Flashcard(id: "new", front: "New", back: "New", draftedAt: cutoff),
            Flashcard(id: "undated", front: "Undated", back: "Undated"),
        ]
        let decks = [MemoryCardDraftDeck(deckID: "deck", sourceID: "filmed", deck: FlashcardDeck(title: "Cards", cards: cards))]
        let shown = scope.scopedCardDrafts(decks)
        #expect(shown.map(\.deckID) == ["deck"])
        #expect(shown[0].deck.cards.map(\.id) == ["new"])
        #expect(decks[0].deck.cards.count == 3, "the stored deck stays intact")
    }

    @Test("Kept cards on a curated source obey the cutoff in listings and due picks, then return when recording stops")
    func keptCardsRespectCutoffWithoutDeletingHistory() async throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        try await withCleanDefaults {
            let store = try KnowledgeStore(inMemory: true)
            try ScreenRecordCourseFixtures.saveSource(store, "filmed", .article, url: "https://example.org/article", addedAt: before)
            let notebook = try store.createCompanionGoal(
                title: "Recording", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["filmed"]
            )
            func card(_ id: String) -> MemoryCard {
                MemoryCard(cardID: id, front: id, back: id, origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "filmed"))
            }
            let old = try store.keepMemoryCard(card("old"), sourceID: "filmed", quote: "Readable text", at: before)
            let fresh = try store.keepMemoryCard(card("fresh"), sourceID: "filmed", quote: "Readable text", at: cutoff)
            // Answered once due (an item is never due on the day it is kept,
            // and an answer before then is not counted), and forgotten: both
            // come due again well before the pick, the older one first.
            for item in [old, fresh] {
                let answeredAt = item.createdAt.addingTimeInterval(86_400 * 2)
                #expect(try store.recordSelfGradedMemoryCardAttempt(
                    memoryItemID: item.id, prompt: item.id, remembered: false, sessionKey: item.id, at: answeredAt
                ) == .recorded)
            }
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setNotebookID(notebook.id)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            #expect(try store.reviewableMemoryItems().items.map(\.id) == [fresh.id])
            #expect(try store.dueMemoryItems(now: cutoff.addingTimeInterval(86_400 * 10), limit: 1, goalID: nil).map { $0.item.id } == [fresh.id])
            ScreenRecordMode.setEnabled(false)
            #expect(Set(try store.reviewableMemoryItems().items.map(\.id)) == [old.id, fresh.id])
            #expect(try store.dueMemoryItems(now: cutoff.addingTimeInterval(86_400 * 10), limit: 1, goalID: nil).map { $0.item.id } == [old.id])
        }
    }

    @Test("Public Apple catalog episodes show with library sources, while private and local episode identities stay hidden")
    func applePodcastIdentitiesRespectPublicScope() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-60)
        var scope = ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: cutoff)
        let publicEpisode = "apple-podcast://episode/123456789"
        #expect(!scope.allowsSource(id: "episode", addedAt: before, kind: "podcast", url: publicEpisode))
        scope.showsLibrarySources = true
        #expect(scope.allowsSource(id: "episode", addedAt: before, kind: "podcast", url: publicEpisode))
        for address in [
            "apple-podcast://episode/private/abcdef", "apple-podcast://episode/local/abcdef",
            "apple-podcast://episode/0", "apple-podcast://episode/-1", "apple-podcast://episode/not-a-number",
            "apple-podcast://episode/123456789?secret=value", "apple-podcast://other/123456789",
        ] {
            #expect(!scope.allowsSource(id: "private", addedAt: before, kind: "podcast", url: address))
        }
        #expect(!scope.allowsSource(id: "private-feed", addedAt: before, kind: "podcast", url: publicEpisode, show: "Private Subscriber Feed"))
        #expect(!scope.allowsSource(id: "upload", addedAt: before, kind: "video", url: publicEpisode))
    }

    @Test("Sources added during a take admit public browser captures, never incidental private sync")
    func newSourcesAreSafeCapturesOnly() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let after = cutoff.addingTimeInterval(60)
        var scope = ScreenRecordScope(notebookID: "notebook", allowedSourceIDs: ["curated-private"], cutoff: cutoff)
        scope.allowedMeetingGroupIDs = ["public-seminar"]

        // The two launch-film workflows: a public Reading List page and an X bookmark.
        #expect(scope.allowsSource(
            id: "reading-list", addedAt: after, kind: "unclassified",
            url: "https://example.org/field-notes", origin: .safari
        ))
        #expect(scope.allowsSource(
            id: "x", addedAt: after, kind: "xPost", url: "https://x.com/example/status/123456789",
            origin: .xBookmarks
        ))
        #expect(scope.allowsSource(
            id: "old-twitter-address", addedAt: after, kind: "xPost",
            url: "https://twitter.com/example/status/123456789", origin: .xBookmarks
        ))
        #expect(scope.allowsSource(
            id: "x-canonical-address", addedAt: after, kind: "xPost",
            url: "https://x.com/i/web/status/123456789", origin: .xBookmarks
        ))
        #expect(scope.allowsSource(
            id: "youtube", addedAt: after, kind: "video", url: "https://www.youtube.com/watch?v=abc",
            origin: .brave
        ))
        #expect(scope.allowsSource(
            id: "course-made-in-take", addedAt: after, kind: "course",
            url: GeneratedCourseLesson.url(courseID: "bioelectricity", module: 1, kind: .lesson)
        ))

        // A profile or search page is not the public post the take deliberately bookmarked.
        #expect(!scope.allowsSource(
            id: "x-profile", addedAt: after, kind: "xPost", url: "https://x.com/example",
            origin: .xBookmarks
        ))
        #expect(!scope.allowsSource(
            id: "x-lookalike", addedAt: after, kind: "xPost", url: "https://x.com.example.org/person/status/1",
            origin: .xBookmarks
        ))

        // Incidental sync never widens the filmed library merely because it is new.
        #expect(!scope.allowsSource(
            id: "meeting", addedAt: after, kind: "meeting", url: "https://zoom.us/rec/share/private", group: "other"
        ))
        #expect(!scope.allowsSource(
            id: "drive", addedAt: after, kind: "article", url: "https://docs.google.com/document/d/private"
        ))
        #expect(!scope.allowsSource(
            id: "upload", addedAt: after, kind: "paper", url: "file:///Users/example/private.pdf"
        ))
        #expect(!scope.allowsSource(id: "pasted", addedAt: after, kind: "article", url: nil))
        #expect(!scope.allowsSource(
            id: "new-book", addedAt: after, kind: "book", url: "file:///Users/example/private.epub"
        ))
        #expect(!scope.allowsSource(
            id: "private-feed", addedAt: after, kind: "podcast", url: "https://example.org/episode",
            show: "Subscriber Feed (🔓 for A Learner)", origin: .applePodcasts
        ))
        #expect(!scope.allowsSource(
            id: "public-feed", addedAt: after, kind: "podcast", url: "https://example.org/episode",
            show: "Example Science", origin: .applePodcasts
        ))
        #expect(!scope.allowsSource(
            id: "followed-video", addedAt: after, kind: "video", url: "https://youtube.com/watch?v=abc",
            origin: .youtubePlaylist
        ))
        #expect(!scope.allowsSource(
            id: "plugin-page", addedAt: after, kind: "article", url: "https://example.org/private",
            origin: .plugin
        ))

        // Deliberate choices win: the curated Notebook and selected seminar folder may hold private URLs.
        #expect(scope.allowsSource(
            id: "curated-private", addedAt: cutoff.addingTimeInterval(-60), kind: "book",
            url: "file:///Users/example/Example Field Guide.epub"
        ))
        #expect(scope.allowsSource(
            id: "seminar", addedAt: after, kind: "meeting", url: "https://meet.example.org/recording/private",
            group: "public-seminar"
        ))
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
        scope.allowedMeetingGroupIDs = ["example-seminar"]
        let url = "https://meet.example.org/recording/private"
        #expect(scope.allowsSource(id: "seminar", addedAt: before, kind: "meeting", url: url, group: "example-seminar"))
        #expect(!scope.allowsSource(id: "standup", addedAt: before, kind: "meeting", url: url, group: "acme-standup"))
        #expect(!scope.allowsSource(id: "loose", addedAt: before, kind: "meeting", url: url, group: nil))
        // The list names meeting folders only: a paper in a folder of that id earns nothing by it.
        #expect(!scope.allowsSource(id: "paper", addedAt: before, kind: "paper", url: nil, group: "example-seminar"))

        try await withCleanDefaults {
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            _ = try await MCPDataStore().setAppSetting(settingID: "recording.meeting_group_ids", value: ["example-seminar"])
            #expect(ScreenRecordMode.meetingGroupIDs == ["example-seminar"])
            #expect(try #require(ScreenRecordScope.resolve { _ in [] }).allowedMeetingGroupIDs == ["example-seminar"])
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

    @Test("A from-scratch take: public sources the learner files into a Notebook made in the take show; older reading, private hosts and meetings never do")
    func takeNotebookSourcesShowOnlyWhenNewAndPublic() {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let before = cutoff.addingTimeInterval(-86_400 * 21)
        let after = cutoff.addingTimeInterval(120)
        var scope = ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: cutoff)
        scope.takeSourceIDs = [
            "talk", "episode", "paper", "article", "post", "book",
            "old-article", "old-kept-article", "zoom", "upload", "drive", "pasted", "profile", "private-feed",
        ]
        scope.keptSourceIDs = ["old-kept-article", "kept-but-unfiled", "kept-meeting"]

        // Discover and Add sources give the source the manual origin; membership vouches for it.
        #expect(scope.allowsSource(
            id: "talk", addedAt: after, kind: "video", url: "https://www.youtube.com/watch?v=abc", origin: .manual
        ))
        #expect(scope.allowsSource(
            id: "episode", addedAt: after, kind: "podcast", url: "https://podcasts.apple.com/us/podcast/example/id1?i=2",
            show: "Example Science", origin: .manual
        ))
        #expect(scope.allowsSource(
            id: "paper", addedAt: after, kind: "paper", url: "https://doi.org/10.1000/example", origin: .manual
        ))
        #expect(scope.allowsSource(
            id: "article", addedAt: after, kind: "article", url: "https://example.org/field-notes", origin: .manual
        ))
        #expect(scope.allowsSource(
            id: "post", addedAt: after, kind: "xPost", url: "https://x.com/example/status/42", origin: .manual
        ))
        #expect(scope.allowsSource(id: "book", addedAt: after, kind: "book", url: nil, origin: .manual))

        // A Discover candidate the library already held is filed into the Notebook with its old date: the
        // learner's other reading does not join the take, unless the admin kept that source.
        #expect(!scope.allowsSource(
            id: "old-article", addedAt: before, kind: "article", url: "https://example.org/old", origin: .manual
        ))
        #expect(scope.allowsSource(
            id: "old-kept-article", addedAt: before, kind: "article", url: "https://example.org/kept", origin: .manual
        ))
        // Kept shows with or without a take Notebook (the learner has to find it to file it), but only
        // while it is public.
        #expect(scope.allowsSource(
            id: "kept-but-unfiled", addedAt: before, kind: "article", url: "https://example.org/kept-two", origin: .manual
        ))
        #expect(!scope.allowsSource(
            id: "kept-meeting", addedAt: before, kind: "meeting", url: "https://zoom.us/rec/share/private", origin: .zoom
        ))
        // Nor does membership alone make a new source public.
        #expect(!scope.allowsSource(
            id: "zoom", addedAt: after, kind: "meeting", url: "https://zoom.us/rec/share/private", origin: .zoom
        ))
        #expect(!scope.allowsSource(id: "upload", addedAt: after, kind: "paper", url: "file:///Users/example/private.pdf"))
        #expect(!scope.allowsSource(id: "drive", addedAt: after, kind: "article", url: "https://docs.google.com/document/d/1"))
        #expect(!scope.allowsSource(id: "pasted", addedAt: after, kind: "article", url: nil))
        #expect(!scope.allowsSource(id: "profile", addedAt: after, kind: "xPost", url: "https://x.com/example"))
        #expect(!scope.allowsSource(
            id: "private-feed", addedAt: after, kind: "podcast", url: "https://example.org/episode",
            show: "Subscriber Feed (🔓 for A Learner)"
        ))
        // A source outside every take Notebook is the narrow answer, however public and new.
        #expect(!scope.allowsSource(
            id: "unfiled", addedAt: after, kind: "article", url: "https://example.org/unfiled", origin: .manual
        ))
        // A caller that cannot say the kind and address gets the narrow answer here too.
        #expect(!scope.allowsSource(id: "talk", addedAt: after))
    }

    @Test("resolve reads a take's own Notebook sources at the cutoff, and the kept list from settings")
    func resolveCarriesTakeAndKeptSources() async throws {
        try await withCleanDefaults {
            let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            _ = try await MCPDataStore().setAppSetting(settingID: "recording.source_ids", value: [" kept ", "kept", "other"])
            #expect(ScreenRecordMode.sourceIDs == ["kept", "other"])

            var askedAt: Date?
            let scope = try #require(ScreenRecordScope.resolve(
                notebookSourceIDs: { _ in [] },
                takeSourceIDs: { cutoff in
                    askedAt = cutoff
                    return ["a", "b", "a"]
                }
            ))
            #expect(askedAt == cutoff)
            #expect(scope.takeSourceIDs == ["a", "b"])
            #expect(scope.keptSourceIDs == ["kept", "other"])

            ScreenRecordMode.setSourceIDs([])
            #expect(ScreenRecordMode.overrideDefaults?.defaults.object(forKey: ScreenRecordMode.sourceIDsKey) == nil)
            #expect(MCPDataStore.appSettingsCatalog().map(\.id).contains("recording.source_ids"))
        }
    }

    @Test("The store answers the sources of the Notebooks and Goals made at or after the cutoff")
    func storeAnswersTakeSources() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        try ScreenRecordCourseFixtures.saveSource(
            store, "from-scratch", .article, url: "https://example.org/from-scratch", addedAt: now
        )
        let notebook = try store.createCompanionGoal(
            title: "Started in the take", topic: "demo", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["from-scratch"]
        )
        #expect(try store.screenRecordTakeSourceIDs(since: now.addingTimeInterval(-3_600)) == ["from-scratch"])
        // A Notebook made before the take holds sources that never ride in on its membership.
        #expect(try store.screenRecordTakeSourceIDs(since: now.addingTimeInterval(3_600)).isEmpty)
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs == ["from-scratch"])
    }

    @Test("Date stamps: only a date from the take is drawn while recording")
    func dateStampsComeFromTheTake() async throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let scope = ScreenRecordScope(notebookID: nil, allowedSourceIDs: [], cutoff: cutoff)
        #expect(!scope.showsDateStamp(cutoff.addingTimeInterval(-86_400 * 21)))
        #expect(scope.showsDateStamp(cutoff))
        #expect(scope.showsDateStamp(cutoff.addingTimeInterval(60)))

        try await withCleanDefaults {
            // Off, every date shows; on, the cutoff decides.
            #expect(ScreenRecordMode.showsDateStamp(cutoff.addingTimeInterval(-86_400)))
            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: cutoff)
            #expect(!ScreenRecordMode.showsDateStamp(cutoff.addingTimeInterval(-86_400)))
            #expect(ScreenRecordMode.showsDateStamp(cutoff.addingTimeInterval(1)))
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

    /// `origin` is where the source came from. Added during the take, only a
    /// browser Reading List capture earns the cutoff pass (70f8842), so the
    /// sources these tests add on camera are Reading List captures.
    private func source(
        _ id: String, _ type: StudioSourceType, addedAt: Date, hidden: Bool = false, group: String? = nil, show: String? = nil,
        origin: DiscoveryOrigin? = nil
    ) -> StudioArticle {
        var article = StudioArticle(url: "https://example.org/\(id)", title: id, sourceType: type, parentGroup: group, id: id)
        article.dateAdded = addedAt
        article.isHidden = hidden
        article.discoveryOrigin = origin
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
            source("added-on-camera", .article, addedAt: after, hidden: true, origin: .safari),
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
            source("paper-added-on-camera", .paper, addedAt: after, origin: .safari),
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

/// The Space sidebar on build 208 (2026-10-10): with the mode on and the
/// Bioelectricity Notebook chosen, the Notebooks row showed only it, but
/// Recents named three of the learner's canvases and Spaces named one of
/// their teams. Recents, Pinned, the spaces and the teams now ask the
/// scope as the Notebooks list does; the Space's own lists and the canvas
/// pickers read the same `listedCanvases` and `listedSpaceLists`.
@Suite("Screen record mode in the Space sidebar")
@MainActor
struct ScreenRecordSpaceSidebarTests {
    private let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var before: Date { cutoff.addingTimeInterval(-3_600) }
    private var after: Date { cutoff.addingTimeInterval(60) }

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordSpaceSidebarTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vm = StudioViewModel(storageService: StorageService(storeRoot: root))
        vm.screenRecordScope = nil
        return vm
    }

    private func page(_ id: String, createdAt: Date, notebook: String? = nil, team: String? = nil) -> ArtifactRecord {
        ArtifactRecord(
            id: id, title: id, homeNotebookID: notebook, linkedNotebookIDs: [], teamID: team, kind: nil,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    private func notebook(_ id: String, createdAt: Date, team: String? = nil) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id, title: id, startAt: createdAt, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: createdAt, updatedAt: createdAt, status: LearningGoalStatus.active.rawValue, items: [],
            kind: LearningGoalRecord.companionKind, teamID: team
        )
    }

    private func team(_ id: String, createdAt: Date) -> TeamRecord {
        TeamRecord(
            id: id, name: id, role: .owner, permission: .readWrite, zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: id), zoneOwnerRecordName: nil, shareRecordName: nil,
            shareURL: nil, createdAt: createdAt, joinedAt: after, updatedAt: createdAt
        )
    }

    private func list(_ id: String, createdAt: Date) -> SpaceList {
        SpaceList(id: id, kind: .goals, name: id, createdAt: createdAt, updatedAt: createdAt, trashedAt: nil)
    }

    @Test("Recents, Pinned, the spaces and the teams show only what the take may show")
    func sidebarFollowsTheScope() throws {
        let vm = makeViewModel()
        try #require(vm.activeTeamID == nil, "My Library, where the Space lists canvases and lists")
        try #require(vm.listsCanvases, "the unit tests run in ForeverLM Dev, which shows the Canvas")

        // The Notebooks first: setting them re-resolves the scope from the
        // host's settings, so the mode is put off again after.
        vm.learningGoals = [
            notebook("recording", createdAt: before),
            notebook("private-notebook", createdAt: before),
            notebook("team-notebook", createdAt: before, team: "team-private"),
        ]
        vm.screenRecordScope = nil
        let pages = [
            page("filmed-page", createdAt: before, notebook: "recording"),
            page("take-page", createdAt: after),
            page("private-page", createdAt: before, notebook: "private-notebook"),
            page("team-page", createdAt: before, team: "team-private"),
        ]
        vm.artifacts = pages
        vm.artifactTeamIDs = ["filmed-page": ["team-shares-filmed"], "team-page": ["team-private"]]
        vm.canvases = KnowledgeMapCanvases([
            KnowledgeMapCanvas(id: "private-canvas", name: "A paper's figures", createdAt: before, updatedAt: before),
            KnowledgeMapCanvas(id: "other-notebook-canvas", name: "Another notebook's map", createdAt: before, updatedAt: before, notebookID: "private-notebook"),
            KnowledgeMapCanvas(id: "filmed-canvas", name: "The recording notebook's map", createdAt: before, updatedAt: before, notebookID: "recording"),
            KnowledgeMapCanvas(id: "take-canvas", name: "Canvas", createdAt: after, updatedAt: after),
        ])
        vm.spaceLists = SpaceLists(lists: [
            "private-list": list("private-list", createdAt: before),
            "take-list": list("take-list", createdAt: after),
        ])
        vm.pageSpaces = PageSpaces(
            names: ["psp-private": "Private", "psp-filmed": "Filmed", "psp-take": "Take"],
            memberships: [
                "private-page": "psp-private", "private-canvas": "psp-private", "private-list": "psp-private",
                "filmed-canvas": "psp-filmed",
                "take-list": "psp-take",
            ]
        )
        vm.pagePins = PagePins(pinnedAt: ["private-canvas": 1, "filmed-canvas": 2, "private-list": 3, "take-list": 4])
        vm.teams = [
            team("team-private", createdAt: before),
            team("team-shares-filmed", createdAt: before),
            team("team-take", createdAt: after),
        ]
        func item(_ kind: SpaceRecents.Item.Kind, _ id: String, drawn: Date? = nil) -> SpaceRecents.Item {
            SpaceRecents.Item(kind: kind, id: id, openedAt: after, title: id, createdAt: drawn)
        }
        let recents = [
            item(.canvas, "private-canvas"), item(.canvas, "take-canvas"), item(.canvas, "other-notebook-canvas"),
            item(.canvas, "filmed-canvas"),
            item(.artifact, "private-page"), item(.artifact, "filmed-page"), item(.artifact, "take-page"),
            item(.list, "private-list"), item(.list, "take-list"),
            item(.image, "old-picture", drawn: before), item(.image, "take-picture", drawn: after),
            item(.image, "kept-picture", drawn: before), item(.image, "undated-picture"),
        ]
        func shown() -> [String] { SpaceSidebar.recentRows(recents, vm: vm, limit: 100).map(\.item.id) }

        // Off (every learner but the admin): everything the library holds.
        #expect(shown() == recents.map(\.id))
        #expect(vm.listedCanvases.count == 4)
        #expect(vm.listedSpaceLists.count == 2)
        #expect(vm.orderedPageSpaces.map(\.id) == ["psp-filmed", "psp-private", "psp-take"])
        #expect(vm.shownTeams.map(\.id) == ["team-private", "team-shares-filmed", "team-take"])

        // On: pages load narrowed (`loadScopedArtifacts`); the rest is
        // narrowed where it is listed.
        vm.screenRecordScope = ScreenRecordScope(
            notebookID: "recording", allowedSourceIDs: [], cutoff: cutoff, allowedImageIDs: ["kept-picture"]
        )
        vm.artifacts = pages.filter { vm.isVisibleInRecordingMode($0) }
        #expect(vm.artifacts.map(\.id) == ["take-page"])

        #expect(shown() == [
            "take-canvas", "take-page", "take-list", "take-picture", "kept-picture",
        ])
        #expect(Set(vm.listedCanvases.map(\.id)) == ["take-canvas"])
        #expect(vm.pinnedCanvases.isEmpty)
        #expect(vm.listedSpaceLists.map(\.id) == ["take-list"])
        #expect(vm.pinnedSpaceLists.map(\.id) == ["take-list"])
        // A space shows while it holds a page, canvas or list on screen.
        #expect(vm.orderedPageSpaces.map(\.id) == ["psp-take"])
        // A team shows when made during the take or holding a page on screen;
        // joined during the take earns nothing (a synced row is stamped so).
        #expect(vm.shownTeams.map(\.id) == ["team-take"])
        // In memory everything stays whole.
        #expect(vm.canvases.all.count == 4)
        #expect(vm.spaceLists.all.count == 2)
        #expect(vm.teams.count == 3)
        #expect(vm.pageSpaces.ordered.count == 3)
    }

    @Test("A team's rule: made during the take, or holding something on screen")
    func teamPredicate() {
        let scope = ScreenRecordScope(notebookID: "recording", allowedSourceIDs: [], cutoff: cutoff)
        #expect(!scope.allowsTeam(createdAt: before, holdsShownItem: false))
        #expect(scope.allowsTeam(createdAt: before, holdsShownItem: true))
        #expect(scope.allowsTeam(createdAt: after, holdsShownItem: false))
    }

    @Test("A picture's drawn date rides its Recents entry across launches")
    func recentsKeepThePictureDate() throws {
        let suite = "ScreenRecordSpaceSidebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drawn = Date(timeIntervalSince1970: 1_790_000_000)
        let recents = SpaceRecents(defaults: defaults)
        recents.note(.image, id: "picture", title: "A cell", createdAt: drawn, at: Date(timeIntervalSince1970: 1_790_000_100))
        recents.note(.artifact, id: "page", at: Date(timeIntervalSince1970: 1_790_000_200))
        let reloaded = SpaceRecents(defaults: defaults)
        #expect(reloaded.items == recents.items)
        #expect(reloaded.items.first { $0.id == "picture" }?.createdAt == drawn)
        #expect(reloaded.items.first { $0.id == "page" }?.createdAt == nil)

        // A newer version drawn since moves the date with the next opening.
        let redrawn = drawn.addingTimeInterval(600)
        recents.note(.image, id: "picture", title: "A cell", createdAt: redrawn, at: Date(timeIntervalSince1970: 1_790_000_300))
        #expect(SpaceRecents(defaults: defaults).items.first?.createdAt == redrawn)
    }
}

/// Screen record mode's answers over MCP say they are narrowed, and which Mac
/// gave them. Each test binds a throwaway defaults suite, as the suite above does.
@Suite("Screen record mode says an answer is narrowed", .serialized)
@MainActor
struct ScreenRecordNarrowedAnswerTests {
    private func withCleanDefaults(_ body: () async throws -> Void) async throws {
        let suiteName = "ScreenRecordNarrowedAnswerTests.\(UUID().uuidString)"
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

    @Test("While recording, a narrowed listing says so, in JSON and in text, and names nothing it leaves out")
    func narrowedListingsSaySo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordModeTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let ks = try store.knowledgeStore()
        let now = Date()
        _ = try ks.createCompanionGoal(
            title: "Private Reading Notebook", topic: "private", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let filmed = try ks.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )

        try await withCleanDefaults {
            // Off: no note, and a listing goes out as it was.
            let unscoped = try store.listNotebooks(includeCompleted: false)
            if !ScreenRecordMode.isForcedByBuild {
                #expect(MCPDataStore.screenRecordNarrowedNote == nil)
                let untouched = MCPToolRegistry.notingScreenRecordNarrowing(.init(text: unscoped, isError: false), toolName: "list_notebooks")
                #expect(untouched.text == unscoped)
            }

            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true, now: now.addingTimeInterval(3_600))
            ScreenRecordMode.setNotebookID(filmed.id)
            let note = try #require(MCPDataStore.screenRecordNarrowedNote)

            // A JSON listing gains the field, and keeps what it said.
            let listed = try store.listNotebooks(includeCompleted: false)
            let noted = MCPToolRegistry.notingScreenRecordNarrowing(.init(text: listed, isError: false), toolName: "list_notebooks")
            let object = try payload(noted.text)
            #expect(object["narrowed"] as? String == note)
            let titles = (object["goals"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            #expect(titles == ["Filmed Notebook"])
            #expect(!noted.text.contains("Private Reading Notebook"), "the note names nothing the take leaves out")
            #expect(!note.contains("Private"))
            #expect(note.range(of: #"\d"#, options: .regularExpression) == nil, "no count of what is left out")

            // A text listing, and an empty listing's sentence, open with it.
            let sources = MCPToolRegistry.notingScreenRecordNarrowing(.init(text: try store.listSources(), isError: false), toolName: "list_sources")
            #expect(sources.text.hasPrefix("Narrowed: \(note)\n\n"))
            let goals = MCPToolRegistry.notingScreenRecordNarrowing(
                .init(text: try store.listNotebookGoals(notebookID: nil), isError: false), toolName: "list_goals"
            )
            #expect(goals.text.hasPrefix("Narrowed: \(note)\n\nNo Goals set yet."))

            // A refusal, and a tool that lists nothing, stay as they are.
            let refusal = MCPToolRegistry.notingScreenRecordNarrowing(.init(text: "Error: no", isError: true), toolName: "list_sources")
            #expect(refusal.text == "Error: no")
            let write = MCPToolRegistry.notingScreenRecordNarrowing(.init(text: "{\"id\": \"x\"}", isError: false), toolName: "create_notebook")
            #expect(write.text == "{\"id\": \"x\"}")
        }
    }

    @Test("get_schedule while recording: only the take's placements, no hidden Notebook in a tag, a hidden one reads as absent")
    func scheduleShowsOnlyTheTake() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecordModeTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let ks = try store.knowledgeStore()
        let now = Date()
        let before = now.addingTimeInterval(-86_400 * 30)
        try ScreenRecordCourseFixtures.saveSource(ks, "kept-reading", .article, url: "https://example.org/kept-reading", addedAt: before)
        try ScreenRecordCourseFixtures.saveSource(ks, "filmed-reading", .article, url: "https://example.org/filmed-reading", addedAt: before)
        let privateNotebook = try ks.createCompanionGoal(
            title: "Private Reading Notebook", topic: "private", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["kept-reading"]
        )
        let filmed = try ks.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["filmed-reading"]
        )
        _ = try await store.assignSourcesToDay(goalID: privateNotebook.id, sourceIDs: ["kept-reading"], dateString: "today")
        _ = try await store.assignSourcesToDay(goalID: filmed.id, sourceIDs: ["filmed-reading"], dateString: "today")
        // The filmed source also serves the private Notebook: its placement carries both tags.
        _ = try await store.assignSourcesToDay(goalID: privateNotebook.id, sourceIDs: ["filmed-reading"], dateString: "today")

        func items(_ text: String) throws -> [[String: Any]] {
            (try payload(text)["days"] as? [[String: Any]] ?? []).flatMap { $0["items"] as? [[String: Any]] ?? [] }
        }

        try await withCleanDefaults {
            if !ScreenRecordMode.isForcedByBuild {
                let all = try items(try store.getSchedule())
                #expect(Set(all.compactMap { $0["source_id"] as? String }) == ["kept-reading", "filmed-reading"])
            }

            ScreenRecordMode.recordAdminStatus(true)
            // The take starts after both Notebooks were made, so only the recording one shows.
            ScreenRecordMode.setEnabled(true, now: now.addingTimeInterval(3_600))
            ScreenRecordMode.setNotebookID(filmed.id)

            let text = try store.getSchedule()
            let listed = try items(text)
            #expect(listed.compactMap { $0["source_id"] as? String } == ["filmed-reading"])
            let tags = listed.first?["goal_tags"] as? [[String: Any]] ?? []
            #expect(tags.compactMap { $0["id"] as? String } == [filmed.id])
            #expect(!text.contains("Private Reading Notebook"), "a hidden Notebook is never named in a tag")
            #expect(!text.contains("kept-reading"), "a hidden placement is not listed")
            let progress = try payload(text)["progress"] as? [String: Any]
            #expect(progress?["total_count"] as? Int == 1, "hidden placements are not counted either")
            #expect(try store.getSchedule(goalID: privateNotebook.id) == "Goal or Notebook not found: \(privateNotebook.id)")
            #expect(try items(try store.getSchedule(goalID: filmed.id)).count == 1)
            #expect(MCPToolRegistry.screenRecordNarrowedToolNames.contains("get_schedule"))
        }
    }

    @Test("The narrowed listings are registered tools, and include the ones a client finds a Notebook or source with")
    func narrowedToolNamesAreRegistered() {
        let registered = Set(MCPToolRegistry.shared.tools.map(\.name))
        let narrowed = MCPToolRegistry.screenRecordNarrowedToolNames
        #expect(narrowed.subtracting(registered).isEmpty, "unknown: \(narrowed.subtracting(registered).sorted())")
        for name in [
            "list_notebooks", "list_goals", "list_sources", "filter_sources", "search_sources_semantic",
            "search_sources_keyword", "get_app_context", "list_notebook_sources",
        ] {
            #expect(narrowed.contains(name), "\(name)")
        }
        let writes = narrowed.filter { !MCPToolRegistry.isReadOnlyTool($0) }
        #expect(writes.isEmpty, "only reads carry the note: \(writes.sorted())")
    }

    @Test("answered_by names the Mac by sync id and model, and its computer name only while the mode is off")
    func answeringMacKeepsTheNameOffATake() {
        let off = MCPDataStore.answeringMac(
            app: "ForeverLM", build: "214", deviceID: "abcd2345", model: "Mac15,8",
            computerName: "Zara's MacBook Pro", screenRecordAvailable: false, screenRecordOn: false
        )
        #expect(off["app"] as? String == "ForeverLM")
        #expect(off["build"] as? String == "214")
        #expect(off["device_id"] as? String == "abcd2345")
        #expect(off["model"] as? String == "Mac15,8")
        #expect(off["computer_name"] as? String == "Zara's MacBook Pro")
        #expect(off["screen_record_mode"] == nil, "a learner who cannot film is never told the mode exists")

        let adminOff = MCPDataStore.answeringMac(
            app: "ForeverLM", build: "214", deviceID: "abcd2345", model: "Mac15,8",
            computerName: "Zara's MacBook Pro", screenRecordAvailable: true, screenRecordOn: false
        )
        #expect(adminOff["screen_record_mode"] as? Bool == false)
        #expect(adminOff["computer_name"] as? String == "Zara's MacBook Pro")

        let filming = MCPDataStore.answeringMac(
            app: "ForeverLM", build: "214", deviceID: "abcd2345", model: "Mac15,8",
            computerName: "Zara's MacBook Pro", screenRecordAvailable: true, screenRecordOn: true
        )
        #expect(filming["screen_record_mode"] as? Bool == true)
        #expect(filming["computer_name"] == nil, "a computer name can hold a person's name, and a take films the answer")
        #expect(filming["device_id"] as? String == "abcd2345")
        #expect(filming["model"] as? String == "Mac15,8")

        // Nothing unknown is made up.
        let bare = MCPDataStore.answeringMac(
            app: "ForeverLM (Dev)", build: nil, deviceID: "", model: nil, computerName: "  ",
            screenRecordAvailable: false, screenRecordOn: false
        )
        #expect(Set(bare.keys) == ["app"])
    }

    @Test("get_mcp_status and get_sync_status say which Mac answered and, while recording, that it is narrowed")
    func statusSaysWhichMacAndWhetherNarrowed() async throws {
        try await withCleanDefaults {
            let store = MCPDataStore()
            if !ScreenRecordMode.isForcedByBuild {
                let status = try payload(try await store.getMCPStatus(toolCount: 1))
                let mac = try #require(status["answered_by"] as? [String: Any])
                #expect(mac["app"] as? String == ForeverLMRuntimeIdentity.displayName)
                #expect(mac["screen_record_mode"] == nil)
                #expect(status["narrowed"] == nil)
            }

            ScreenRecordMode.recordAdminStatus(true)
            ScreenRecordMode.setEnabled(true)
            let note = try #require(MCPDataStore.screenRecordNarrowedNote)
            let mcpStatus = try await store.getMCPStatus(toolCount: 1)
            let syncStatus = try await store.getSyncStatus()
            for text in [mcpStatus, syncStatus] {
                let status = try payload(text)
                let mac = try #require(status["answered_by"] as? [String: Any])
                #expect(mac["screen_record_mode"] as? Bool == true)
                #expect(mac["computer_name"] == nil)
                #expect(status["narrowed"] as? String == note)
            }
        }
    }

    @Test("What every client reads names no mode: the server instructions and the status tools speak only of narrowed")
    func publicWordsNameNoMode() throws {
        let instructions = Prompts.mcpServerInstructions
        #expect(instructions.contains("never choose the closest match"))
        #expect(instructions.contains("answered_by"))
        for name in ["get_mcp_status", "get_sync_status"] {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name })
            #expect(tool.description.contains("answered_by"))
            #expect(tool.description.contains("narrowed"))
            #expect(!tool.description.localizedCaseInsensitiveContains("screen record"))
            #expect(!tool.description.localizedCaseInsensitiveContains("recording"))
        }
        #expect(!instructions.localizedCaseInsensitiveContains("screen record"))
    }
}

#endif

@Suite("Screen record mode hides the account name")
struct ScreenRecordAccountNameTests {
    @Test("While recording, the rail and greeting show the stand-in, never the saved name")
    func recordingShowsTheStandIn() {
        let shown = MacAccountUser.displayedFullName(saved: "Ada Lovelace", recording: true)
        #expect(shown == MacAccountUser.recordingStandInName)
        #expect(MacAccountUser.leadingName(of: shown) == "Richard")
        #expect(MacAccountUser.monogram(of: shown) == "R")
        // Off the take, the saved name is what shows.
        #expect(MacAccountUser.displayedFullName(saved: "Ada Lovelace", recording: false)
            == MacAccountUser.resolvedFullName(saved: "Ada Lovelace"))
    }
}
