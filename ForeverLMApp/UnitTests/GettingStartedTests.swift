import AppKit
import Foundation
import Testing
@testable import ForeverLM

@Suite("Getting Started")
struct GettingStartedTests {
    @Test("First-source guidance supports every Reading List ForeverLM reads")
    func firstSourceBrowserChoices() {
        #expect(ReadingListBrowser.allCases == [.safari, .chrome, .brave])
        #expect(ReadingListBrowser.safari.preference == .safari)
        #expect(ReadingListBrowser.chrome.preference == .chrome)
        #expect(ReadingListBrowser.brave.preference == .brave)
        #expect(ReadingListBrowser.safari.saveInstruction.contains("Add to Reading List"))
        #expect(ReadingListBrowser.chrome.saveInstruction.contains("Add current tab"))
        #expect(ReadingListBrowser.brave.saveInstruction.contains("Add current tab"))
    }

    @Test("New guide steps take new bits and every step sits in one section")
    func guideStepsAreGroupedAndStable() {
        // `completedSteps` is synced, so the original bits never move.
        #expect(GettingStartedStep.podcasts.rawValue == 0)
        #expect(GettingStartedStep.article.rawValue == 1)
        #expect(GettingStartedStep.paper.rawValue == 2)
        #expect(GettingStartedStep.youtube.rawValue == 3)
        #expect(GettingStartedStep.books.rawValue == 6)
        #expect(GettingStartedStep.assistants.rawValue == 13)
        #expect(GettingStartedStep.subscriptions.rawValue == 14)
        #expect(GettingStartedStep.fullDiskAccess.rawValue == 15)
        #expect(GettingStartedStep.moreSources.rawValue == 16)
        #expect(GettingStartedSection.setup.steps == [.fullDiskAccess, .enhancements])

        let grouped = GettingStartedSection.allCases.flatMap(\.steps)
        #expect(grouped == GettingStartedStep.onboardingOrder)
        #expect(GettingStartedSection.sources.steps == [.podcasts, .article, .paper, .moreSources])
        // Connecting the AI app closes Setup, once the library has something
        // for the connector to reach (product owner, 2026-09-25).
        #expect(GettingStartedSection.assistant.steps == [.subscriptions])
        #expect(GettingStartedStep.onboardingOrder.last == .subscriptions)
        // The tour left setup on 2026-09-24; its cases stay for their bits.
        #expect(GettingStartedSection.workspace.steps.isEmpty)
        #expect(!GettingStartedSection.sources.steps.contains { $0.isTour })
    }

    @Test("Setup is seven screens: every other step is a More sources row or retired")
    func setupKeepsToFewScreens() {
        let order = GettingStartedStep.onboardingOrder
        #expect(order.count == 7)
        #expect(GettingStartedStep.moreSourceRows == [.books, .courses, .meetings, .youtube])
        #expect(GettingStartedStep.moreSourceRows.allSatisfy { !order.contains($0) && $0.section == .sources })
        let retired: Set<GettingStartedStep> = [.storage, .planner, .memory, .ideas, .artifacts, .assistants]
        #expect(retired.isDisjoint(with: order))
        #expect(Set(order).union(GettingStartedStep.moreSourceRows).union(retired) == Set(GettingStartedStep.allCases))
        // Each row's symbol draws, like every step's.
        #expect(NSImage(systemSymbolName: GettingStartedStep.moreSources.icon, accessibilityDescription: nil) != nil)
    }

    @Test("A question's picks each get a page, in order, and then the step is done")
    func followUpPagesWalkThePicksInOrder() {
        let picks: [GettingStartedStep] = [.books, .youtube]
        #expect(GettingStartedFlow.next(after: nil, in: picks) == .books)
        #expect(GettingStartedFlow.next(after: .books, in: picks) == .youtube)
        #expect(GettingStartedFlow.next(after: .youtube, in: picks) == nil)
        // No picks ("None of these", or "No" to an AI app): no pages at all.
        #expect(GettingStartedFlow.next(after: nil, in: [GettingStartedStep]()) == nil)
        // A pick unticked after its page opened has no next page.
        #expect(GettingStartedFlow.next(after: .courses, in: picks) == nil)
    }

    @Test("The footer shows one way forward: Continue, Finish, Skip or a waiting Continue")
    func footerShowsOneWayForward() {
        #expect(GettingStartedFlow.forward(canContinue: true, canSkip: true, isLast: false) == .next)
        #expect(GettingStartedFlow.forward(canContinue: true, canSkip: false, isLast: true) == .finish)
        // Skip only stands in for a Continue that cannot be pressed yet.
        #expect(GettingStartedFlow.forward(canContinue: false, canSkip: true, isLast: false) == .skip)
        #expect(GettingStartedFlow.forward(canContinue: false, canSkip: true, isLast: true) == .skip)
        // The AI step and the questions with a "none" answer wait instead.
        #expect(GettingStartedFlow.forward(canContinue: false, canSkip: false, isLast: false) == .waiting)
    }

    @Test("The subscription answer tells unanswered, no and each pick apart")
    func aiSubscriptionAnswerRoundTrips() {
        #expect(AISubscription.decode("") == nil)
        #expect(AISubscription.encode(nil) == "")
        #expect(AISubscription.decode(AISubscription.encode([])) == [])
        let picks: Set<AISubscription> = [.grok, .claude]
        // Stored in the enum's order, whatever order they were ticked in.
        #expect(AISubscription.encode(picks) == "claude,grok")
        #expect(AISubscription.decode("claude,grok") == picks)
        // A pick from a newer build is still a subscription, not "unanswered".
        #expect(AISubscription.decode("perplexity") == [.other])
        #expect(SyncedPreferenceKeys.isSynced(AISubscription.storageKey))
    }

    @Test("Every AI app's connector steps point at the address")
    func aiSubscriptionConnectorSteps() {
        for subscription in AISubscription.allCases {
            #expect(!subscription.connectorSteps.isEmpty)
            #expect(subscription.connectorSteps.contains { $0.contains("address below") })
        }
    }

    @Test("The connector plan knows each AI app by the name it registered")
    func connectedAssistantNames() {
        #expect(AISubscription.matching(clientName: "Claude") == .claude)
        #expect(AISubscription.matching(clientName: "Claude Code (foreverlm)") == .claude)
        #expect(AISubscription.matching(clientName: "ChatGPT") == .chatGPT)
        #expect(AISubscription.matching(clientName: "Codex") == .chatGPT)
        #expect(AISubscription.matching(clientName: "Grok") == .grok)
        #expect(AISubscription.matching(clientName: "Gemini") == .gemini)
        #expect(AISubscription.matching(clientName: "Perplexity") == .other)
        // ForeverLM's own clients (the reviewer, importers) are no one's AI app.
        #expect(AISubscription.matching(clientName: "ForeverLM live reviewer verification") == nil)
    }

    @Test("Every connector walkthrough clip films the steps the plan shows now")
    func connectorWalkthroughsAreCurrent() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/WelcomeClipsResources")
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("connector-clips.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let clips = try #require(manifest["clips"] as? [String: Any])
        for subscription in AISubscription.allCases {
            let name = subscription.walkthroughClip
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).mp4").path) else {
                continue
            }
            let entry = clips[name] as? [String: Any]
            #expect(entry != nil, "\(name).mp4 has no entry in connector-clips.json")
            #expect(
                entry?["steps"] as? [String] == subscription.connectorSteps,
                "\(name).mp4 was recorded against other steps; re-record it or remove it"
            )
            #expect(entry?["recorded"] is String, "\(name) needs the day it was recorded")
        }
        // An entry without its clip is a leftover from a removed recording.
        for name in clips.keys {
            #expect(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).mp4").path),
                "connector-clips.json lists \(name) but the clip is gone"
            )
        }
    }

    @Test("Every guide step draws a real SF Symbol")
    func guideStepIconsExist() {
        // An unknown symbol name renders nothing; Podcasts shipped blank as "podcasts".
        for step in GettingStartedStep.allCases {
            #expect(
                NSImage(systemSymbolName: step.icon, accessibilityDescription: nil) != nil,
                "\(step.title) has no symbol named \(step.icon)"
            )
        }
    }

    @Test("Every moment and page of the welcome story has a real symbol")
    func welcomeStoryIconsExist() {
        let icons = WelcomeStory.day.map(\.icon) + [WelcomeStory.rememberIcon, WelcomeStory.yourAIIcon, WelcomeStory.yourDataIcon]
        for icon in icons {
            #expect(
                NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil,
                "The welcome story has no symbol named \(icon)"
            )
        }
    }

    @Test("The welcome day runs in order along its timeline, and the quote's book is on it")
    func welcomeDayRunsInOrder() {
        let hours = WelcomeStory.day.map(\.hours)
        #expect(hours == hours.sorted())
        #expect(hours.allSatisfy { (7...23).contains($0) })
        #expect(Set(WelcomeStory.day.map(\.id)).count == WelcomeStory.day.count)
        #expect(WelcomeStory.day.contains { $0.icon == WelcomeStory.halfRememberedIcon })
    }

    @Test("The Reading List recommendation follows the default browser's bundle ID")
    func readingListBrowserFromBundleIdentifier() {
        #expect(ReadingListBrowser(bundleIdentifier: "com.apple.Safari") == .safari)
        #expect(ReadingListBrowser(bundleIdentifier: "com.google.Chrome") == .chrome)
        #expect(ReadingListBrowser(bundleIdentifier: "com.brave.Browser") == .brave)
        #expect(ReadingListBrowser(bundleIdentifier: "company.thebrowser.Browser") == nil)
        #expect(ReadingListBrowser(bundleIdentifier: nil) == nil)
    }

    @Test("Get started suggestions show only after setup, until all are done")
    func getStartedSuggestionsVisibility() {
        let all = GetStartedSuggestions.allDone
        #expect(!GetStartedSuggestions.isShowing(armed: false, doneBits: 0))
        #expect(GetStartedSuggestions.isShowing(armed: true, doneBits: 0))
        #expect(GetStartedSuggestions.isShowing(armed: true, doneBits: GetStartedSuggestions.Suggestion.read.bit))
        #expect(!GetStartedSuggestions.isShowing(armed: true, doneBits: all))
        for suggestion in GetStartedSuggestions.Suggestion.allCases {
            #expect(NSImage(systemSymbolName: suggestion.icon, accessibilityDescription: nil) != nil)
        }
    }

    @Test("A saved OpenRouter key is refused only when OpenRouter says it is not a key")
    func ownKeyCheckStatuses() {
        #expect(ManagedAI.ownKeyCheckResult(statusCode: 200, router: .openRouter) == .accepted)
        if case .rejected(let reason) = ManagedAI.ownKeyCheckResult(statusCode: 401, router: .openRouter) {
            #expect(reason.contains("OpenRouter"))
        } else {
            Issue.record("401 should reject the key")
        }
        #expect(ManagedAI.ownKeyCheckResult(statusCode: 403, router: .openRouter) != .accepted)
        // An outage or a rate limit says nothing about the key: no verdict.
        #expect(ManagedAI.ownKeyCheckResult(statusCode: 500, router: .openRouter) == nil)
        #expect(ManagedAI.ownKeyCheckResult(statusCode: 429, router: .openRouter) == nil)
    }

    @Test("Free-model requests left come from OpenRouter's key info and reset at UTC midnight")
    func freeModelDailyRequests() throws {
        let body = Data(#"{"data":{"label":"sk-or-v1-au7...890","is_free_tier":false,"free_model_daily_requests":{"limit":1000,"remaining":962,"used":38}}}"#.utf8)
        let counts = try #require(ManagedAI.freeModelDailyRequests(fromKeyInfo: body))
        #expect(counts == ManagedAI.FreeModelDailyRequests(used: 38, limit: 1000, remaining: 962))
        #expect(ManagedAI.freeModelDailyRequests(fromKeyInfo: Data(#"{"data":{"label":"x"}}"#.utf8)) == nil)
        #expect(ManagedAI.freeModelDailyRequests(fromKeyInfo: Data("not json".utf8)) == nil)

        // 20:30 UTC on 2026-09-28 is 13:30 in California; the count starts
        // again at the next UTC midnight, 17:00 there. The rest of the
        // clock's spelling is the locale's, so only the time is pinned.
        let now = Date(timeIntervalSince1970: 1_790_627_400)
        #expect(ManagedAI.FreeModelDailyRequests.resetDate(after: now) == Date(timeIntervalSince1970: 1_790_640_000))
        #expect(ManagedAI.FreeModelDailyRequests.resetDate(after: Date(timeIntervalSince1970: 1_790_640_000))
            == Date(timeIntervalSince1970: 1_790_726_400))
        let california = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let english = Locale(identifier: "en_GB")
        let summary = counts.summary(now: now, locale: english, timeZone: california)
        #expect(summary.hasPrefix("962 of 1,000 left · resets at "))
        #expect(summary.contains("17:00"))
        let spent = ManagedAI.FreeModelDailyRequests(used: 50, limit: 50, remaining: 0)
        #expect(spent.summary(now: now, locale: english, timeZone: california).hasPrefix("None of 50 left · resets at "))
    }

    @Test("Apple Books index rows become importable books, previews and other formats left out")
    func appleBooksIndexRows() {
        let rows: [[String: Any]] = [
            [
                "path": "/b/Doctored 1.epub",
                "itemName": "Doctored: Fraud, Arrogance, and Tragedy",
                "artistName": "Charles Piller",
                "isPreview": false,
            ],
            ["path": "/b/Sample.epub", "itemName": "Sample", "isPreview": true],
            ["path": "/b/Audio.m4b", "itemName": "Audio"],
            ["path": "/b/Notes.pdf", "BKDisplayName": "Notes", "artistName": ""],
            ["itemName": "No path"],
        ]
        let books = AppleBooksLibrary.books(fromIndex: rows)
        #expect(books.map(\.title) == ["Doctored: Fraud, Arrogance, and Tragedy", "Notes"])
        #expect(books.first?.author == "Charles Piller")
        #expect(books.last?.author == nil)
    }

    @Test("Future-only YouTube policy keeps new likes and existing sources")
    func futureOnlyLikedVideoFiltering() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let oldExisting = YouTubePlaylistItem(
            videoId: "existing",
            title: "Existing",
            likedAt: Date(timeIntervalSince1970: 900)
        )
        let oldIgnored = YouTubePlaylistItem(
            videoId: "ignored",
            title: "Ignored",
            likedAt: Date(timeIntervalSince1970: 900)
        )
        let newLike = YouTubePlaylistItem(
            videoId: "new",
            title: "New",
            likedAt: cutoff
        )

        let filtered = StudioViewModel.eligibleLikedVideoItems(
            [oldExisting, oldIgnored, newLike],
            policy: .futureOnly,
            cutoff: cutoff,
            existingURLKeys: [StudioViewModel.sourceURLIdentityKey(oldExisting.url)]
        )

        #expect(filtered.map(\.videoId) == ["existing", "new"])
    }

    @Test("Import-existing YouTube policy does not filter history")
    func importExistingLikedVideoFiltering() {
        let item = YouTubePlaylistItem(
            videoId: "old",
            title: "Old",
            likedAt: Date(timeIntervalSince1970: 100)
        )

        let filtered = StudioViewModel.eligibleLikedVideoItems(
            [item],
            policy: .importExisting,
            cutoff: Date(timeIntervalSince1970: 1_000),
            existingURLKeys: []
        )

        #expect(filtered.map(\.videoId) == ["old"])
    }

    @Test("YouTube liked sync unions fresh ratings with playlist timestamps")
    func youtubeLikedFeedUnion() {
        let likedAt = Date(timeIntervalSince1970: 1_000)
        let playlistItem = YouTubePlaylistItem(
            videoId: "known",
            title: "Playlist title",
            likedAt: likedAt
        )
        let ratedKnown = YouTubePlaylistItem(videoId: "known", title: "Rating title")
        let ratedFresh = YouTubePlaylistItem(videoId: "fresh", title: "Fresh rating")

        let merged = YouTubeService.mergeLikedVideoFeeds(
            playlist: ([playlistItem], true),
            ratings: ([ratedFresh, ratedKnown], true)
        )

        #expect(merged.items.map(\.videoId) == ["fresh", "known"])
        #expect(merged.items[1].likedAt == likedAt)
        #expect(merged.isComplete)
    }

    @Test("YouTube liked union remains incomplete when either API view is truncated")
    func youtubeLikedFeedUnionCompleteness() {
        let merged = YouTubeService.mergeLikedVideoFeeds(
            playlist: ([], true),
            ratings: ([], false)
        )
        #expect(!merged.isComplete)
    }

    @Test("Getting-started and YouTube setup choices use the synced SQLite preference rail")
    func setupPreferencesAreSynced() {
        #expect(SyncedPreferenceKeys.isSynced("gettingStarted.completed"))
        #expect(SyncedPreferenceKeys.isSynced("gettingStarted.dismissed"))
        #expect(SyncedPreferenceKeys.isSynced("gettingStarted.completedSteps"))
        #expect(SyncedPreferenceKeys.isSynced("youtube.likedTranscriptFormattingEnabled"))
    }

    @Test("The storage step keeps the synced step bits stable")
    func storageStepAppendsItsBit() {
        // `completedSteps` is synced already, so a new step takes a new bit.
        #expect(GettingStartedStep.storage.rawValue == 5)
        #expect(GettingStartedStep.enhancements.rawValue == 4)
    }

    @Test("Setup's AI step needs the OpenRouter key on an account that may run it, or another way to pay")
    func aiStepNeedsKeyTheAccountMayRun() {
        // The proxy refuses the key on an account it may not run on: a locked
        // one in the paid app (2026-10-10; the free days run it). So a key
        // alone, or an unlocked account alone, pays for nothing.
        #expect(GettingStartedAIPayment.isReady(hasOwnKey: true, ownKeyAllowed: true, canPayWithoutKey: false))
        #expect(!GettingStartedAIPayment.isReady(hasOwnKey: true, ownKeyAllowed: false, canPayWithoutKey: false))
        #expect(!GettingStartedAIPayment.isReady(hasOwnKey: false, ownKeyAllowed: true, canPayWithoutKey: false))
        #expect(!GettingStartedAIPayment.isReady(hasOwnKey: false, ownKeyAllowed: false, canPayWithoutKey: false))
        // A comp, or balance left from before top-ups were retired, still pays.
        #expect(GettingStartedAIPayment.isReady(hasOwnKey: false, ownKeyAllowed: false, canPayWithoutKey: true))
    }

    @Test("Every Setup step that asks a question names its options and can be answered")
    func setupStepsAskAnswerableQuestions() {
        // Setup is the part that cannot be skipped, so each of its steps has
        // to state what the choice is rather than assume a default.
        #expect(GettingStartedSection.setup.steps == [.fullDiskAccess, .enhancements])

        // Storage asks nothing since 2026-09-24: every library syncs with
        // iCloud, and the welcome's data row says so.

        // Subscriptions: answering "no" is an answer, not an empty tick list.
        #expect(AISubscription.allCases.isEmpty == false)
    }

    @Test("Full Disk Access is asked for before the steps that need it")
    func fullDiskAccessPrecedesPodcastsAndReadingLists() throws {
        let order = GettingStartedStep.onboardingOrder
        let access = try #require(order.firstIndex(of: .fullDiskAccess))
        for needsAccess in [GettingStartedStep.podcasts, .article, .paper] {
            #expect(access < order.firstIndex(of: needsAccess)!, "\(needsAccess.title) comes before Full Disk Access")
        }
    }

    @Test("A full iCloud is reported once and clears when uploads get through")
    @MainActor
    func iCloudFullFlag() async {
        let center = CloudKitSyncStatusCenter(completionSettleDelay: .zero)
        let posts = PostCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudKitICloudStorageDidFill, object: nil, queue: nil
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        center.setICloudFull(true)
        center.setICloudFull(true)
        #expect(center.isICloudFull)
        #expect(posts.value == 1)
        center.setICloudFull(false)
        #expect(!center.isICloudFull)
    }

    @Test("Background tasks stay blocked until credit consent, which follows the account")
    func backgroundConsentGatesEveryBackgroundTask() {
        // Full Disk Access opens Setup, then consent, both before any import.
        #expect(
            Array(GettingStartedStep.onboardingOrder.prefix(2))
                == [.fullDiskAccess, .enhancements]
        )

        let task = AITask.transcriptFormatting
        let consentKey = KeychainService.backgroundAIUsageConsentKey
        let originalConsent = UserDefaults.standard.object(forKey: consentKey)
        defer {
            if let originalConsent {
                UserDefaults.standard.set(originalConsent, forKey: consentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: consentKey)
            }
        }

        KeychainService.hasConsentedToBackgroundAIUsage = false
        #expect(!KeychainService.isAIUsageAllowed(for: task))
        // Chat is initiated by a click, so it never waits on the acknowledgement.
        #expect(KeychainService.isAIUsageAllowed(for: .chat))
        #expect(KeychainService.backgroundAIUnavailableMessage(for: task) != nil)

        // Consent is the only switch: every background pass runs once it is given.
        KeychainService.hasConsentedToBackgroundAIUsage = true
        #expect(KeychainService.isAIUsageAllowed(for: task))
        #expect(KeychainService.isAIUsageAllowed(for: .paperBrowserAgent))
        #expect(KeychainService.backgroundAIUnavailableMessage(for: task) == nil)

        #expect(SyncedPreferenceKeys.isSynced(consentKey))
    }
}

/// Settings › Data & Privacy › iCloud's storage figure (`ICloudStorageUsage`).
@Suite("iCloud storage usage")
struct ICloudStorageUsageTests {
    @Test("Only what iCloud holds for the learner's own library counts, in bytes")
    func syncedSourceStorageCountsWhatICloudHolds() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.exec("""
            INSERT INTO sources (id, date_added, state, source_type, status) VALUES
                ('paper', 0, 'ready', 'paper', 'active'),
                ('paper-unsent', 0, 'ready', 'paper', 'active'),
                ('paper-deleted', 0, 'ready', 'paper', 'active'),
                ('paper-team', 0, 'ready', 'paper', 'active'),
                ('paper-deferred', 0, 'ready', 'paper', 'active'),
                ('article', 0, 'ready', 'article', 'active'),
                ('podcast', 0, 'ready', 'podcast', 'active');
            INSERT INTO papers (source_id, url, local_file_path) VALUES
                ('paper', 'https://doi.org/10.1/a', 'Papers/a.pdf'),
                ('paper-unsent', 'https://doi.org/10.1/b', 'Papers/b.pdf'),
                ('paper-deleted', 'https://doi.org/10.1/c', 'Papers/c.pdf'),
                ('paper-team', 'https://doi.org/10.1/d', 'Papers/d.pdf'),
                ('paper-deferred', 'https://doi.org/10.1/e', 'Papers/e.pdf');
            INSERT INTO articles (source_id, url) VALUES ('article', 'https://example.com/a');
            INSERT INTO podcasts (source_id, url, raw_ttml) VALUES
                ('podcast', 'https://example.com/p', '<tt>12345</tt>');
            INSERT INTO source_content (source_id, content) VALUES
                ('paper', '0123456789'),
                ('paper-unsent', 'not in iCloud yet'),
                ('paper-deleted', 'gone from iCloud'),
                ('paper-team', 'billed to the team creator'),
                ('paper-deferred', 'content not sent yet'),
                ('article', 'héllo');
            INSERT INTO paper_content_preparations (source_id, raw_content, raw_sha256) VALUES
                ('paper', '01234567890123456789', 'x'),
                ('article', 'a paper preparation an article record never carries', 'x');
            INSERT INTO article_content_preparations (source_id, raw_content, raw_sha256) VALUES
                ('article', 'raw', 'x');
            INSERT INTO podcast_transcript_preparations
                (source_id, input_content, input_sha256, clean_sha256) VALUES
                ('podcast', 'input', 'x', 'y');
            INSERT INTO source_listenable_content
                (source_id, source_sha256, content, generator_version, prepared_at) VALUES
                ('paper', 'x', 'listen', 1, 0);
            INSERT INTO sync_metadata
                (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted, zone_scope) VALUES
                ('source', 'paper', 'r-paper', X'01', 0, 0, 'private'),
                ('source', 'paper-unsent', 'r-paper-unsent', NULL, 0, 0, 'private'),
                ('source', 'paper-deleted', 'r-paper-deleted', X'01', 0, 1, 'private'),
                ('source', 'paper-team', 'r-paper-team', X'01', 0, 0, 'shared'),
                ('source', 'paper-deferred', 'r-paper-deferred', X'01', 0, 0, 'private'),
                ('source', 'article', 'r-article', X'01', 0, 0, 'private'),
                ('source', 'podcast', 'r-podcast', X'01', 0, 0, 'private');
            INSERT INTO sync_asset_digests (record_name, field, digest) VALUES
                ('r-paper-deferred', '\(KnowledgeStore.deferredContentMarkerField)', 'deferred');
        """)

        let synced = try store.iCloudSyncedSourceStorage()

        #expect(synced.pdfPaths == [
            ICloudSyncedSourceStorage.StoredPath(localFilePath: "Papers/a.pdf", url: "https://doi.org/10.1/a"),
        ])
        // paper: 10 + 20 + 6 (listen). article: "héllo" is 6 bytes, not 5
        // characters, + 3; the paper preparation on it never ships. podcast:
        // 14 of TTML + 5 of input.
        #expect(synced.textBytes == 36 + 9 + 19)
    }

    @Test("A PDF counts at its size once, and iCloud Drive at every file's logical size")
    func measureCountsFilesAtTheirSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        func write(_ relative: String, bytes: Int, sparse: Bool = false) throws -> String {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sparse {
                #expect(fm.createFile(atPath: url.path, contents: nil))
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(bytes))
                try handle.close()
            } else {
                #expect(fm.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes)))
            }
            return url.path
        }

        let paper = try write("Library/a.pdf", bytes: 1_234)
        let byURL = try write("Library/b.pdf", bytes: 766)
        let book = try write("Library/book.epub", bytes: 50)
        let tooLarge = try write(
            "Library/huge.pdf",
            bytes: CloudKitRecordMapper.maxPaperPDFAssetBytes + 1,
            sparse: true
        )
        _ = try write("Drive/Documents/ForeverLM/Audio/a.m4a", bytes: 100)
        _ = try write("Drive/Documents/ForeverLM Dev/Audio/b.m4a", bytes: 250)
        // An evicted file keeps its logical size, and iCloud still bills it.
        _ = try write("Drive/Documents/ForeverLM/Audio/evicted.m4a", bytes: 1_000_000, sparse: true)

        let usage = ICloudStorageUsage.measure(
            ICloudSyncedSourceStorage(
                pdfPaths: [
                    .init(localFilePath: paper, url: "https://doi.org/10.1/a"),
                    // Not on this Mac by its path, so the URL is tried, as
                    // `resolvedPDFPath` tries it.
                    .init(localFilePath: root.appendingPathComponent("Library/missing.pdf").path, url: byURL),
                    .init(localFilePath: book, url: nil),
                    .init(localFilePath: tooLarge, url: nil),
                    .init(localFilePath: nil, url: "https://example.com/never-downloaded.pdf"),
                ],
                textBytes: 42
            ),
            driveRoot: root.appendingPathComponent("Drive", isDirectory: true)
        )

        #expect(usage.documentBytes == 2_000)
        #expect(usage.textBytes == 42)
        #expect(usage.driveBytes == 1_000_350)
        #expect(usage.totalBytes == 2_000 + 42 + 1_000_350)
    }

    @Test("iCloud Drive is ForeverLM's whole iCloud Documents folder, whichever profile's folder a file sits in")
    func driveRootIsTheWholeContainer() {
        #expect(ForeverLMRuntimeIdentity.iCloudDocumentsFolderName == "iCloud~com~foreverlm")
        #expect(ICloudStorageUsage.driveContainerRootPath.hasSuffix("/Library/Mobile Documents/iCloud~com~foreverlm"))
    }
}

private final class PostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
