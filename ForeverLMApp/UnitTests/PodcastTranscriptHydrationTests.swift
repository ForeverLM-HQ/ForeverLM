// The source reload and podcast transcript formatting and hydration tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - Source Reloads

@Suite("Source Reloads")
@MainActor
struct SourceReloadTests {

    @Test("refreshArticles preserves loaded transcript content")
    func refreshArticlesPreservesLoadedTranscriptContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReloadTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        var stored = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "Podcast Episode",
            sourceType: .podcast,
            state: .ready,
            discoveryOrigin: .applePodcasts
        )
        stored.domain = "Example Podcast"
        stored.content = "Stored transcript text."
        stored.wordCount = 3
        try await service.saveSource(stored)

        var opened = stored
        opened.content = "This transcript was already loaded in the reader."
        opened.wordCount = 8
        vm.articles = [opened]

        await vm.refreshArticles()

        #expect(vm.articles.first?.content == opened.content)
        #expect(vm.articles.first?.wordCount == opened.wordCount)
    }
}

// MARK: - Podcast Transcript Hydration

@Suite("Podcast Transcript Formatting Annotations")
struct PodcastTranscriptFormattingAnnotationTests {

    @Test("ad-read annotations remove only the exact sponsored span")
    func removesExactAdReadSpan() {
        let transcript = """
        [SPEAKER_1]
        Welcome to the show. Today we are tracing how cells turn nutrients into usable energy and why that process changes under stress. This episode is brought to you by Accenture. Accenture helps businesses reinvent how they work. Visit accenture.com to learn more. Now let's discuss how cells generate energy, how mitochondria respond to demand, and what the experimental evidence actually shows.
        """
        let response = """
        [
          {"after":"Welcome to the show.","speaker":"Host"},
          {
            "ad_start":"This episode is brought to you by Accenture.",
            "ad_end":"Visit accenture.com to learn more."
          }
        ]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(!formatted.contains("brought to you by Accenture"))
        #expect(!formatted.contains("accenture.com"))
        // The transcript names its speaker on a label line, so the break goes
        // in and the model's speaker does not.
        #expect(formatted.contains("Welcome to the show.\n\n Today we are tracing"))
        #expect(!formatted.contains("**Host:**"))
        #expect(formatted.contains("Now let's discuss how cells generate energy,"))
    }

    @Test("a diarized transcript keeps its own speaker lines: no marker above a label, no blank-line runs")
    func diarizedTranscriptTakesBreaksWithoutSpeakers() {
        let transcript = """
        [Ada Lovelace]
        The engine weaves algebraic patterns. It could compose music of any complexity.

        [Charles Babbage]
        That was never my intention for the machine.
        """
        // The shapes stored transcripts showed on 2026-10-06: a speaker break
        // right before the next turn's label (a `**Name:**` above `[Name]`),
        // the same break twice (blank lines stacked), and a speaker mid-turn
        // that the label lines contradict.
        let response = """
        [
          {"after":"music of any complexity.","speaker":"Charles Babbage"},
          {"after":"music of any complexity."},
          {"after":"weaves algebraic patterns.","speaker":"Charles Babbage"}
        ]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == """
        [Ada Lovelace]
        The engine weaves algebraic patterns.

         It could compose music of any complexity.

        [Charles Babbage]
        That was never my intention for the machine.
        """)
        // A chunk inside one long turn holds no label line; the caller says
        // the transcript is diarized, and the speaker is still left out.
        let insideATurn = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: "The engine weaves algebraic patterns. It could compose music of any complexity.",
            from: #"[{"after":"weaves algebraic patterns.","speaker":"Charles Babbage"}]"#,
            transcriptIsDiarized: true
        )
        #expect(insideATurn == "The engine weaves algebraic patterns.\n\n It could compose music of any complexity.")
    }

    @Test("a break where the text already breaks adds nothing, and a speaker named there opens the next paragraph")
    func existingBreaksAreNotStacked() {
        // Where an ad was taken out, the text already breaks.
        let diarized = "[SPEAKER_1]\nWe start with the question of energy. This episode is brought to you by Example Corp, the makers of examples. Visit example.com today for a discount. Now back to the mitochondria and the membrane potential they hold across the inner membrane. It is the potential the dyes in these experiments read, and it falls when the cell is stressed."
        let afterAd = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: diarized,
            from: """
            [{"ad_start":"This episode is brought to you by Example Corp,","ad_end":"Visit example.com today for a discount."},
             {"after":"the question of energy."}]
            """
        )
        #expect(afterAd == "[SPEAKER_1]\nWe start with the question of energy.\n\nNow back to the mitochondria and the membrane potential they hold across the inner membrane. It is the potential the dyes in these experiments read, and it falls when the cell is stressed.")

        // A transcript with no speaker lines keeps the model's speakers, and
        // one named at an existing break opens the paragraph after it.
        let plain = "The host finishes the introduction.\n\nThe guest begins the explanation. And goes on at length."
        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: plain,
            from: """
            [{"after":"finishes the introduction.","speaker":"Guest"},
             {"after":"begins the explanation.","speaker":"Host"}]
            """
        )
        #expect(formatted == "The host finishes the introduction.\n\n**Guest:** The guest begins the explanation.\n\n**Host:**  And goes on at length.")
        #expect(!formatted.contains("\n\n\n"))
    }

    @Test("ambiguous ad boundaries preserve the transcript")
    func ambiguousBoundaryIsNotDeleted() {
        let transcript = """
        This episode is brought to you by Example. First editorial section.
        This episode is brought to you by Example. Second editorial section.
        """
        let response = """
        [{
          "ad_start":"This episode is brought to you by Example.",
          "ad_end":"Second editorial section."
        }]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == transcript)
    }

    @Test("over-broad ad annotations cannot erase most of a transcript")
    func overBroadRemovalIsRejected() {
        let transcript = "Opening editorial sentence. "
            + String(repeating: "sponsored message ", count: 80)
            + "Closing editorial sentence."
        let response = """
        [{
          "ad_start":"Opening editorial sentence.",
          "ad_end":"Closing editorial sentence."
        }]
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == transcript)
    }

    @Test("legacy breakpoint-only responses remain supported")
    func legacyBreakPointResponseStillWorks() {
        let transcript = "The host finishes the introduction. The guest begins the explanation."
        let response = """
        ```json
        [{"after":"The host finishes the introduction.","speaker":"Guest"}]
        ```
        """

        let formatted = StudioViewModel.applyPodcastTranscriptBreakPointsOffMain(
            to: transcript,
            from: response
        )

        #expect(formatted == "The host finishes the introduction.\n\n**Guest:**  The guest begins the explanation.")
    }
}

/// A value a `@Sendable` closure can record into from any thread.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

@Suite("Podcast Transcript Hydration")
@MainActor
struct PodcastTranscriptHydrationCandidateTests {

    private func makeEpisode(id: String, show: String) -> StudioArticle {
        var article = makeArticle(
            url: "apple-podcast://episode/1000751939405",
            title: "Episode \(id)",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: id
        )
        article.domain = show
        return article
    }

    @Test("visible episodes allow transcript formatting")
    func visibleEpisodeAllowsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "visible", show: "Example Podcast")]

        let candidate = vm.podcastHydrationCandidate(for: "visible")
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("episodes on a hidden show skip transcript formatting")
    func hiddenShowSkipsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "hidden-show", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]

        let candidate = vm.podcastHydrationCandidate(for: "hidden-show")
        #expect(candidate?.allowsFormatting == false)
    }

    @Test("individually hidden episodes skip transcript formatting")
    func hiddenEpisodeSkipsFormatting() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "hidden-episode", show: "Example Podcast")]
        vm.hiddenPodcastEpisodeIDs = ["hidden-episode"]

        let candidate = vm.podcastHydrationCandidate(for: "hidden-episode")
        #expect(candidate?.allowsFormatting == false)
    }

    @Test("a visible episode on a hidden show still formats")
    func visibleOverrideOnHiddenShowFormats() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "override", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]
        vm.visiblePodcastEpisodeOverrideIDs = ["override"]

        let candidate = vm.podcastHydrationCandidate(for: "override")
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("a show hidden while a bulk drain waits stops formatting its queued episodes")
    func showHiddenMidDrainSkipsFormattingAtDispatch() throws {
        let vm = makeViewModel()
        vm.articles = [
            makeEpisode(id: "queued", show: "Example Podcast"),
            makeEpisode(id: "other", show: "Other Podcast"),
        ]
        let queued = try #require(vm.podcastHydrationCandidate(for: "queued"))
        let other = try #require(vm.podcastHydrationCandidate(for: "other"))
        #expect(queued.allowsFormatting)

        vm.hiddenPodcastShows = ["Example Podcast"]

        #expect(vm.bulkHydrationCandidateAtDispatch(queued).allowsFormatting == false)
        #expect(vm.bulkHydrationCandidateAtDispatch(other).allowsFormatting)
    }

    @Test("a show hidden in the installed library is never formatted automatically by a Dev build")
    func installedLibraryHiddenShowSkipsFormatting() {
        let vm = makeViewModel()
        let hiddenThere = makeEpisode(id: "hidden-there", show: "TBPN")
        let override = makeEpisode(id: "override", show: "TBPN")
        let visible = makeEpisode(id: "visible", show: "Example Podcast")
        vm.articles = [hiddenThere, override, visible]
        vm.visiblePodcastEpisodeOverrideIDs = [override.id]
        let installed: Set<String> = ["TBPN"]

        #expect(!vm.allowsTranscriptFormatting(
            for: hiddenThere, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: hiddenThere, userInitiated: true, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: override, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        #expect(vm.allowsTranscriptFormatting(
            for: visible, userInitiated: false, installedLibraryHiddenShows: installed
        ))
        // The Dev library still lists the episode as a stranger would see it.
        #expect(!vm.isSourceHidden(hiddenThere))
    }

    @Test("the installed library's hidden shows are read only by a Dev build")
    func installedLibraryHiddenShowsLoad() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("knowledge.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            CREATE TABLE hidden_podcast_shows (show_name TEXT PRIMARY KEY, hidden_at REAL NOT NULL);
            INSERT INTO hidden_podcast_shows VALUES ('TBPN', 0), ('All-In', 0);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(InstalledLibraryHiddenPodcastShows.load(isDevelopment: true, databaseURL: url)
            == ["TBPN", "All-In"])
        #expect(InstalledLibraryHiddenPodcastShows.load(isDevelopment: false, databaseURL: url)
            .isEmpty)
        #expect(InstalledLibraryHiddenPodcastShows.load(
            isDevelopment: true,
            databaseURL: folder.appendingPathComponent("missing.db")
        ).isEmpty)
    }

    @Test("automatic podcast work excludes hidden episodes but honors a visible override")
    func automaticPodcastWorkExcludesHiddenSources() {
        let vm = makeViewModel()
        let visible = makeEpisode(id: "visible", show: "Visible Show")
        let hiddenShow = makeEpisode(id: "hidden-show", show: "Hidden Show")
        var hiddenEpisode = makeEpisode(id: "hidden-episode", show: "Visible Show")
        hiddenEpisode.isHidden = true
        let override = makeEpisode(id: "override", show: "Hidden Show")
        var staleCached = makeEpisode(id: "stale-cached", show: "Visible Show")
        staleCached.content = "Already stored transcript"
        vm.articles = [visible, hiddenShow, hiddenEpisode, override, staleCached]
        vm.hiddenPodcastShows = ["Hidden Show"]
        vm.hiddenPodcastEpisodeIDs = [hiddenEpisode.id]
        vm.visiblePodcastEpisodeOverrideIDs = [override.id]

        #expect(
            vm.pendingAutomaticPodcastTranscriptArticles().map(\.id)
                == [visible.id, override.id, staleCached.id]
        )
    }

    @Test("stored podcast transcripts are repaired before slow transcript fetches")
    func storedPodcastTranscriptsTakeQueuePriority() {
        let firstSlow = makeEpisode(id: "first-slow", show: "Example Podcast")
        let cached = makeEpisode(id: "cached", show: "Example Podcast")
        let secondSlow = makeEpisode(id: "second-slow", show: "Example Podcast")

        #expect(
            StudioViewModel.prioritizedPodcastTranscriptIDs(
                [firstSlow, cached, secondSlow],
                storedContentLengths: [cached.id: 42_000]
            ) == [cached.id, firstSlow.id, secondSlow.id]
        )
    }

    @Test("a library reload preserves the active podcast transcript state")
    func reloadPreservesActivePodcastState() {
        var active = makeEpisode(id: "active", show: "Example Podcast")
        active.state = .fetching
        var reloaded = active
        reloaded.state = .queued

        let merged = StudioViewModel.preservingLoadedContent(
            in: [reloaded],
            preservingFrom: [active]
        )

        #expect(merged.first?.state == .fetching)
    }

    @Test("user-confirmed hydration formats even on a hidden show")
    func userInitiatedOverridesHidden() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "confirmed", show: "Example Podcast")]
        vm.hiddenPodcastShows = ["Example Podcast"]

        let candidate = vm.podcastHydrationCandidate(for: "confirmed", userInitiated: true)
        #expect(candidate?.allowsFormatting == true)
    }

    @Test("a show-level YouTube preference reaches transcript hydration")
    func youtubePreferenceReachesHydration() {
        let vm = makeViewModel()
        vm.articles = [makeEpisode(id: "youtube-show", show: "Mind & Matter")]
        vm.podcastYouTubeFallbackShows = ["mind & matter"]

        let candidate = vm.podcastHydrationCandidate(for: "youtube-show")
        #expect(candidate?.prefersYouTube == true)

        let audioOptIn = vm.podcastHydrationCandidate(
            for: "youtube-show",
            userInitiated: true,
            honorYouTubePreference: false
        )
        #expect(audioOptIn?.prefersYouTube == false)
    }

    @Test("Apple transcript HTTP status distinguishes unavailable access from retryable failures")
    func transcriptHTTPStatusClassification() {
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 200) == .success)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 401) == .authenticationExpired)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 403) == .failed)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 404) == .unavailable)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 429) == .failed)
        #expect(StudioViewModel.podcastTranscriptHTTPDisposition(statusCode: 503) == .failed)
    }

    @Test("only terminal transcript errors suppress retries")
    func terminalTranscriptErrors() {
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.noPodcastTranscriptMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.unavailablePodcastTranscriptMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.podcastAudioTranscriptionMessage))
        #expect(StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.youtubePreferredPodcastTranscriptMessage))
        #expect(!StudioViewModel.isTerminalPodcastTranscriptError(StudioViewModel.retryablePodcastTranscriptMessage))
        #expect(!StudioViewModel.isTerminalPodcastTranscriptError(nil))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.noPodcastTranscriptMessage))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.unavailablePodcastTranscriptMessage))
        #expect(StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.podcastAudioTranscriptionMessage))
        #expect(!StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.retryablePodcastTranscriptMessage))
        #expect(!StudioViewModel.canOptInToPodcastAudioTranscription(StudioViewModel.youtubePreferredPodcastTranscriptMessage))
    }

    @Test("missing Apple TTML does not transcribe audio without opt-in")
    func missingAppleTranscriptRequiresAudioOptIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAudioOptInTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "audio-opt-in-required", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in
                Issue.record("Automatic hydration tried to resolve episode audio.")
                return URL(string: "https://example.com/episode.mp3")
            },
            transcribeEpisodeAudio: { _ in
                Issue.record("Automatic hydration started paid audio transcription.")
                return "This must not be used."
            }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.unavailablePodcastTranscriptMessage)
        case .ready:
            Issue.record("Audio transcription ran without explicit opt-in.")
        }
        #expect(await storage.loadSourceContent(episode.id) == nil)
    }

    @Test("explicit opt-in transcribes exact episode audio")
    func optedInMissingAppleTranscriptUsesEpisodeAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAudioFallbackTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "audio-fallback", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/episode.mp3") },
            transcribeEpisodeAudio: { _ in "Transcript produced from the exact episode audio." }
        )

        switch result.outcome {
        case .ready(let content, let persistedReadyState):
            #expect(content == "Transcript produced from the exact episode audio.")
            #expect(persistedReadyState)
        case .failed(let message):
            Issue.record("Expected audio fallback to succeed, got: \(message)")
        }
        #expect(await storage.loadSourceContent(episode.id) == "Transcript produced from the exact episode audio.")
    }

    @Test("retryable Apple transcript failures never start paid audio transcription")
    func retryableAppleTranscriptFailureDoesNotUseAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastAppleRetryTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "apple-retry", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .failed },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/episode.mp3") },
            transcribeEpisodeAudio: { _ in "This must not be used." }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.retryablePodcastTranscriptMessage)
        case .ready:
            Issue.record("A retryable Apple failure incorrectly started paid audio transcription.")
        }
        #expect(await storage.loadSourceContent(episode.id) == nil)
    }

    @Test("a show set to find YouTube leaves an episode that already has its transcript alone")
    func youtubePreferenceKeepsStoredTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastYouTubePreferenceTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "youtube-preferred-done", show: "Example Podcast")
        try await storage.saveSource(episode)
        try await storage.savePodcastYouTubeTranscript(
            episode.id,
            "Transcript taken from the confirmed YouTube upload.",
            youtubeURL: "https://www.youtube.com/watch?v=abc123"
        )
        vm.articles = [episode]
        let base = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let candidate = StudioViewModel.PodcastTranscriptHydrationCandidate(
            id: base.id,
            url: base.url,
            title: base.title,
            podcastName: base.podcastName,
            webPageURL: base.webPageURL,
            prefersYouTube: true,
            allowsFormatting: base.allowsFormatting
        )

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A finished episode asked Apple for its transcript again.")
                return .unavailable
            }
        )

        switch result.outcome {
        case .ready(let content, _):
            #expect(content == "Transcript taken from the confirmed YouTube upload.")
        case .failed(let message):
            Issue.record("A finished episode was sent back to find YouTube: \(message)")
        }
    }

    // MARK: - Rows without a public identity

    private static let privateFeedName = "The Peter Attia Drive - Private Subscriber Feed (🔓 for Robin Vale)"

    private static let publicTwin = PodcastPublicEpisode(
        trackID: 1000415911177,
        title: "Dom D'Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
        episodeNumber: 5,
        webPageURL: "https://peterattiamd.com/domdagostino/"
    )

    private static let appleTTML = """
    <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
      <body><div>
        <p begin='0.0' end='1.0' ttm:agent='SPEAKER_1'>Dom, welcome to the show.</p>
        <p begin='1.0' end='2.0' ttm:agent='SPEAKER_2'>Thanks for having me, Peter.</p>
      </div></body>
    </tt>
    """

    /// The reported shape: an episode a named private feed filed under its web
    /// page, holding the page as content. Rows like it hydrate now — the row
    /// is eligible, its page text is not content, and the public twin's Apple
    /// transcript replaces it under the public identity.
    private func makeWebPageEpisode(id: String, show: String = privateFeedName) -> StudioArticle {
        var article = makeArticle(
            url: "https://peterattiamd.com/domdagostino/",
            title: "#05 – Dom D’Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
            sourceType: .podcast,
            discoveryOrigin: .manual,
            id: id
        )
        article.domain = show
        return article
    }

    @Test("a web-page row from a named feed is eligible, a pasted page is not")
    func webPageRowEligibility() {
        let vm = makeViewModel()
        let fromFeed = makeWebPageEpisode(id: "feed-page")
        var pasted = makeWebPageEpisode(id: "pasted-page")
        pasted.domain = "peterattiamd.com"
        vm.articles = [fromFeed, pasted]

        #expect(vm.podcastHydrationCandidate(for: "feed-page")?.url == fromFeed.url)
        #expect(vm.podcastHydrationCandidate(for: "pasted-page") == nil)
        #expect(vm.pendingAutomaticPodcastTranscriptArticles().map(\.id) == ["feed-page"])
    }

    @Test("a web-page row resolves to its public twin, takes its identity, and gets Apple's transcript")
    func webPageRowResolvesToPublicEpisode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPublicIdentityTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeWebPageEpisode(id: "page-row")
        try await storage.saveSource(episode)
        // The page text an older build wrote is what this repairs.
        try await storage.saveTranscript(episode.id, "# Topics Discussed\n- Dom's early training [7:00]")
        episode.state = .queued
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let fetchedTrackIDs = LockedBox<[Int64]>([])
        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { trackID, _ in
                fetchedTrackIDs.mutate { $0.append(trackID) }
                return .available(Self.appleTTML)
            },
            resolvePublicEpisode: { showName, title, _ in
                #expect(showName == Self.privateFeedName)
                #expect(title.hasPrefix("#05"))
                return .matched(Self.publicTwin, showName: "The Peter Attia Drive")
            }
        )

        #expect(fetchedTrackIDs.value == [1000415911177])
        #expect(result.resolvedIdentity == StudioViewModel.PodcastResolvedEpisodeIdentity(
            url: "apple-podcast://episode/1000415911177",
            webPageURL: "https://peterattiamd.com/domdagostino/"
        ))
        switch result.outcome {
        case .ready(let content, _):
            #expect(content.contains("Dom, welcome to the show."))
            #expect(!content.contains("Topics Discussed"))
        case .failed(let message):
            Issue.record("Expected the public twin's transcript, got: \(message)")
        }

        await vm.applyPodcastHydrationResult(result)
        let inMemory = try #require(vm.articles.first(where: { $0.id == episode.id }))
        #expect(inMemory.url == "apple-podcast://episode/1000415911177")
        #expect(inMemory.podcastWebPageURL == "https://peterattiamd.com/domdagostino/")
        #expect(inMemory.state == .ready)

        let stored = try #require(try await storage.loadActiveSources().first(where: { $0.id == episode.id }))
        #expect(stored.url == "apple-podcast://episode/1000415911177")
        #expect(stored.podcastWebPageURL == "https://peterattiamd.com/domdagostino/")
        #expect(stored.state == .ready)
        #expect(await storage.loadSourceContent(episode.id)?.contains("Thanks for having me, Peter.") == true)
        #expect(try await storage.loadPodcastRawTTML(episode.id) == Self.appleTTML)
    }

    @Test("page text under a web-page address is never returned as the episode's content")
    func webPageTextIsNotContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPageTextTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeWebPageEpisode(id: "notes-only")
        try await storage.saveSource(episode)
        try await storage.saveTranscript(episode.id, "# Show Notes\nA page, not a transcript.")
        episode.state = .queued
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("No public twin, so Apple must not be asked.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )

        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.noPublicPodcastEpisodeMessage)
            #expect(StudioViewModel.isTerminalPodcastTranscriptError(message))
            #expect(StudioViewModel.canOptInToPodcastAudioTranscription(message))
        case .ready:
            Issue.record("Show notes were returned as a podcast's content.")
        }
        #expect(result.resolvedIdentity == nil)
    }

    @Test("a private-feed placeholder with no public twin keeps the audio opt-in route")
    func privatePlaceholderWithoutTwin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPrivateTwinTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var episode = makeArticle(
            url: "apple-podcast://episode/private/6566f059f9b527e0ebe15c8679582a61b6567c869842f161a67fac68ac4746b6",
            title: "#400 ‒ AMA #87: Environmental pollution and longevity",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "private-row"
        )
        episode.domain = Self.privateFeedName
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let automatic = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A private placeholder has no track id to ask Apple about.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )
        switch automatic.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.noPublicPodcastEpisodeMessage)
        case .ready:
            Issue.record("Nothing here can produce a transcript automatically.")
        }

        // The explicit Transcribe Audio action still reaches the exact enclosure.
        let optedIn = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            allowAudioTranscription: true,
            fetchAppleTranscript: { _, _ in .unavailable },
            resolveEpisodeAudioURL: { _, _, _ in URL(string: "https://example.com/private-episode.mp3") },
            transcribeEpisodeAudio: { _ in "Transcript from the private feed's own audio." },
            resolvePublicEpisode: { _, _, _ in .noMatchingEpisode }
        )
        switch optedIn.outcome {
        case .ready(let content, _):
            #expect(content == "Transcript from the private feed's own audio.")
        case .failed(let message):
            Issue.record("Expected the opt-in audio route to run, got: \(message)")
        }
    }

    @Test("a resolver outage keeps the row retryable")
    func resolverOutageIsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastResolverOutageTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeWebPageEpisode(id: "outage-row")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in .available(Self.appleTTML) },
            resolvePublicEpisode: { _, _, _ in .failed }
        )
        switch result.outcome {
        case .failed(let message):
            #expect(message == StudioViewModel.retryablePodcastTranscriptMessage)
            #expect(!StudioViewModel.isTerminalPodcastTranscriptError(message))
        case .ready:
            Issue.record("A resolver outage must not produce a transcript.")
        }
        let stored = try #require(try await storage.loadActiveSources().first(where: { $0.id == episode.id }))
        #expect(stored.url == episode.url)
    }

    @Test("a row whose public twin is already in the library is folded into it")
    func duplicateRowIsMergedIntoExistingEpisode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastDuplicateMergeTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)

        var existing = makeArticle(
            url: "apple-podcast://episode/1000415911177",
            title: "Dom D'Agostino, Ph.D.: ketosis",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "public-row"
        )
        existing.domain = "The Peter Attia Drive"
        try await storage.saveSource(existing)
        try await storage.saveTranscript(existing.id, "Peter Attia: Dom, welcome.", rawTTML: Self.appleTTML)
        existing.state = .ready

        let duplicate = makeWebPageEpisode(id: "page-duplicate")
        try await storage.saveSource(duplicate)
        vm.articles = [existing, duplicate]
        vm.selectedArticleId = duplicate.id
        let candidate = try #require(vm.podcastHydrationCandidate(for: duplicate.id))

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: nil,
            fetchAppleTranscript: { _, _ in
                Issue.record("A merged row must not fetch a second copy of the transcript.")
                return .unavailable
            },
            resolvePublicEpisode: { _, _, _ in .matched(Self.publicTwin, showName: "The Peter Attia Drive") }
        )
        #expect(result.mergedIntoSourceID == existing.id)

        await vm.applyPodcastHydrationResult(result)
        #expect(vm.articles.map(\.id) == [existing.id])
        #expect(vm.selectedArticleId == existing.id)

        let active = try await storage.loadActiveSources().map(\.id)
        #expect(active == [existing.id])
        #expect(await storage.loadSourceContent(existing.id) == "Peter Attia: Dom, welcome.")
    }

    // MARK: - Readable before formatting

    /// A long run of speech from SPEAKER_1 across twelve of Apple's paragraphs,
    /// then a short answer from SPEAKER_2.
    nonisolated private static let longEpisodeTTML: String = {
        let host = (0..<12).map {
            "<p begin='\($0).0' end='\($0 + 1).0' ttm:agent='SPEAKER_1'>Replay during slow-wave sleep is what moves a memory from fragile to durable. Here is point \($0).</p>"
        }.joined(separator: "\n")
        return """
        <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
        \(host)
            <p begin='20.0' end='21.0' ttm:agent='SPEAKER_2'>Thanks for having me, Zara.</p>
          </div></body>
        </tt>
        """
    }()

    private static let formattingConfig = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "example/formatter")

    @Test("an Apple transcript is saved ready at once, in paragraphs, and its formatting waits in the queue")
    func appleTranscriptReadsBeforeFormatting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastReadsAtOnceTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "reads-at-once", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let candidate = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let extracted = try SourceService.extractTextFromTTMLContent(Self.longEpisodeTTML)

        let result = await StudioViewModel.hydratePodcastTranscript(
            candidate,
            storage: storage,
            homeDir: "/tmp",
            config: Self.formattingConfig,
            fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
        )

        guard case .ready(let content, let persistedReadyState) = result.outcome else {
            Issue.record("Expected the transcript to be ready at once, got \(result.outcome)")
            return
        }
        #expect(persistedReadyState)
        // No model ran: the speakers are still Apple's, and the long turn is cut
        // into paragraphs by code alone.
        #expect(content == StudioViewModel.readablePodcastTranscriptLayout(extracted))
        #expect(content.hasPrefix("[SPEAKER_1]\nReplay during slow-wave sleep"))
        #expect(content.components(separatedBy: "\n\n").count > 2)
        #expect(content.hasSuffix("\n\n[SPEAKER_2]\nThanks for having me, Zara."))
        #expect(StudioViewModel.podcastTranscriptWithoutLayout(content) == extracted)
        #expect(await storage.loadSourceContent(episode.id) == content)
        #expect(try await storage.loadPodcastRawTTML(episode.id) == Self.longEpisodeTTML)

        let queued = try await storage.podcastTranscriptCleanupCandidates(limit: 5)
        #expect(queued.map(\.sourceID) == [episode.id])
        #expect(queued.first?.formatsTranscript == true)
        #expect(queued.first?.input == content)

        await vm.applyPodcastHydrationResult(result)
        let loaded = try #require(vm.articles.first { $0.id == episode.id })
        #expect(loaded.state == .ready)
        #expect(loaded.content == content)
    }

    @Test("an episode that may not pay for formatting is saved readable and never queued for it")
    func unformattableEpisodeIsNotQueued() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastHiddenReadableTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let episode = makeEpisode(id: "hidden-readable", show: "Example Podcast")
        try await storage.saveSource(episode)
        vm.articles = [episode]
        let base = try #require(vm.podcastHydrationCandidate(for: episode.id))
        let hidden = StudioViewModel.PodcastTranscriptHydrationCandidate(
            id: base.id,
            url: base.url,
            title: base.title,
            podcastName: base.podcastName,
            webPageURL: base.webPageURL,
            prefersYouTube: false,
            allowsFormatting: false
        )

        for (candidate, config) in [(hidden, Self.formattingConfig), (base, nil)] as [(StudioViewModel.PodcastTranscriptHydrationCandidate, AITaskConfig?)] {
            let result = await StudioViewModel.hydratePodcastTranscript(
                candidate,
                storage: storage,
                homeDir: "/tmp",
                config: config,
                forceRefresh: true,
                fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
            )
            guard case .ready(let content, _) = result.outcome else {
                Issue.record("Expected a readable transcript, got \(result.outcome)")
                continue
            }
            #expect(content.hasPrefix("[SPEAKER_1]\n"))
            #expect(await storage.loadSourceContent(episode.id) == content)
            #expect(try await storage.podcastTranscriptCleanupCandidates(limit: 5).allSatisfy { !$0.formatsTranscript })
        }
    }

    @Test("an episode the learner asked for is queued ahead of the rest")
    func learnerAskedEpisodeGoesFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastLearnerAskedTests_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        var bulk = makeArticle(
            url: "apple-podcast://episode/1000751939406",
            title: "Episode bulk-episode",
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: "bulk-episode"
        )
        bulk.domain = "Example Podcast"
        let asked = makeEpisode(id: "asked-episode", show: "Example Podcast")
        try await storage.saveSource(bulk)
        try await storage.saveSource(asked)
        vm.articles = [bulk, asked]
        let bulkCandidate = try #require(vm.podcastHydrationCandidate(for: bulk.id))
        let askedCandidate = try #require(vm.podcastHydrationCandidate(for: asked.id, userInitiated: true))
        #expect(!bulkCandidate.userInitiated && askedCandidate.userInitiated)

        for candidate in [bulkCandidate, askedCandidate] {
            _ = await StudioViewModel.hydratePodcastTranscript(
                candidate,
                storage: storage,
                homeDir: "/tmp",
                config: Self.formattingConfig,
                fetchAppleTranscript: { _, _ in .available(Self.longEpisodeTTML) }
            )
        }

        let queued = try await storage.podcastTranscriptCleanupCandidates(limit: 5)
        #expect(queued.map(\.sourceID) == [asked.id, bulk.id])
        #expect(queued.allSatisfy { $0.formatsTranscript })
    }

    @Test("podcast YouTube fallback show keys ignore case and whitespace")
    func podcastYouTubeFallbackShowKey() {
        #expect(StudioViewModel.podcastShowPreferenceKey("  Mind & Matter  ") == "mind & matter")
    }

    @Test("YouTube recovery search includes the episode and podcast names")
    func youtubeRecoverySearchQuery() {
        var episode = makeEpisode(id: "youtube-search", show: "Mind & Matter")
        episode.title = "Neuro-Immune Interactions"

        #expect(
            StudioViewModel.podcastYouTubeSearchQuery(for: episode)
                == "Neuro-Immune Interactions Mind & Matter"
        )
    }

    @Test("YouTube recovery accepts semantic queries for differently titled uploads")
    func youtubeRecoverySemanticQueries() throws {
        let response = """
        {"queries":["Alex Colville Core Memory","Core Memory longevity Alex Colville"]}
        """

        #expect(
            try AIService.decodePodcastYouTubeSearchQueries(response)
                == ["Alex Colville Core Memory", "Core Memory longevity Alex Colville"]
        )
    }

    @Test("YouTube recovery ranking keeps every candidate and can prefer a different title")
    func youtubeRecoverySemanticRanking() throws {
        let response = """
        {"ranked_video_ids":["same-episode","literal-title"]}
        """

        #expect(
            try AIService.decodePodcastYouTubeRanking(
                response,
                expectedVideoIDs: ["literal-title", "same-episode"]
            ) == ["same-episode", "literal-title"]
        )
    }

    @Test("YouTube recovery rejects rankings that drop a candidate")
    func youtubeRecoveryRejectsPartialRanking() {
        #expect(throws: AIError.self) {
            try AIService.decodePodcastYouTubeRanking(
                "{\"ranked_video_ids\":[\"same-episode\"]}",
                expectedVideoIDs: ["same-episode", "another-video"]
            )
        }
    }

    @Test("YouTube recovery merges query results once and applies semantic order")
    func youtubeRecoveryMergesAndRanksCandidates() {
        let literal = YouTubeVideoSearchResult(
            videoId: "literal-title",
            title: "The Realest Longevity Guru - EP 85 Alex Colville",
            channelTitle: "Other Channel",
            description: nil,
            publishedAt: nil
        )
        let semantic = YouTubeVideoSearchResult(
            videoId: "same-episode",
            title: "The Longevity Expert Who Takes Nothing",
            channelTitle: "Core Memory Podcast",
            description: "Alex Colville is the longevity investor we call when someone claims to have found the fountain of youth.",
            publishedAt: nil
        )
        let merged = StudioViewModel.mergedPodcastYouTubeSearchResults([
            (1, [semantic]),
            (0, [literal, semantic]),
        ])

        #expect(merged.map(\.videoId) == ["literal-title", "same-episode"])
        #expect(
            StudioViewModel.rankedPodcastYouTubeSearchResults(
                merged,
                videoIDs: ["same-episode", "literal-title"]
            ).map(\.videoId) == ["same-episode", "literal-title"]
        )
    }

    @Test("YouTube recovery finds the upload an episode's page links most, in markup and JSON")
    func youtubeRecoveryReadsEpisodePageLinks() {
        // Core Memory's EP 90 page (2026-09-30): the upload linked once plainly
        // and again at every chapter time, and one other video in the notes.
        let html = """
        <a href="https://www.youtube.com/watch?v=Cqer4ApweVM">Watch</a>
        <a href="https://youtu.be/OsaIqiLnzRo">An earlier talk</a>
        <li><a href="https://www.youtube.com/watch?v=Cqer4ApweVM&amp;t=308s">5:08</a> Intro</li>
        <li><a href="https://www.youtube.com/watch?v=Cqer4ApweVM&amp;t=1179s">19:39</a> Ice</li>
        <script>{"embed":"https:\\/\\/www.youtube-nocookie.com\\/embed\\/Cqer4ApweVM"}</script>
        <a href="https://www.youtube.com/@CoreMemorypodcast">Channel</a>
        """

        #expect(StudioViewModel.youtubeVideoIDsLinked(inEpisodePage: html) == ["Cqer4ApweVM", "OsaIqiLnzRo"])
        #expect(StudioViewModel.youtubeVideoIDsLinked(inEpisodePage: "<p>No video here.</p>").isEmpty)
        #expect(
            StudioViewModel.youtubeVideoIDsLinked(
                inEpisodePage: #"<a href="https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ">x</a>"#
            ) == ["dQw4w9WgXcQ"]
        )
    }

    @Test("YouTube recovery offers the show's uploads nearest the day the episode arrived")
    func youtubeRecoveryPicksChannelUploadsNearTheEpisode() {
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        func upload(_ id: String, daysFromEpisode days: Double?) -> YouTubePlaylistItem {
            YouTubePlaylistItem(
                videoId: id,
                title: id,
                playlistIndex: nil,
                channelTitle: "Core Memory Podcast",
                likedAt: nil,
                videoPublishedAt: days.map { added.addingTimeInterval($0 * 86_400) }
            )
        }
        let uploads = [
            upload("same-day", daysFromEpisode: -0.2),
            upload("next-week", daysFromEpisode: 6),
            upload("last-month", daysFromEpisode: -30),
            upload("undated", daysFromEpisode: nil),
            upload("two-days-on", daysFromEpisode: 2),
            upload("nine-days-back", daysFromEpisode: -9),
        ]

        #expect(
            StudioViewModel.uploadsNearEpisode(uploads, addedAt: added)
                == ["same-day", "two-days-on", "next-week"]
        )
        #expect(StudioViewModel.uploadsNearEpisode(uploads, addedAt: added, limit: 10).count == 4)
    }

    @Test("YouTube video lookups keep the order asked and the uploader's channel")
    func youtubeVideoListKeepsRequestedOrder() throws {
        let json = """
        {"items":[
          {"id":"second","snippet":{"title":"Can We Put Death On Hold?","channelId":"UCabcdefghijklmnopqrstuv","channelTitle":"Core Memory Podcast","publishedAt":"2026-09-30T12:00:06Z"}},
          {"id":"first","snippet":{"title":"Tom &amp; Jerry","channelTitle":"Other"}}
        ]}
        """
        let response = try JSONDecoder().decode(VideoListResponse.self, from: Data(json.utf8))
        let results = YouTubeService.videoListResults(from: response, orderedBy: ["first", "missing", "second"])

        #expect(results.map(\.videoId) == ["first", "second"])
        #expect(results.first?.title == "Tom & Jerry")
        #expect(results.last?.channelId == "UCabcdefghijklmnopqrstuv")
        #expect(results.last?.publishedAt != nil)
    }

    @Test("An assistant names the YouTube video by its address or its id")
    func podcastYouTubeImportReadsTheVideoArgument() {
        #expect(MCPDataStore.youtubeVideoID(fromArgument: " Cqer4ApweVM ") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "https://www.youtube.com/watch?v=Cqer4ApweVM&t=308s") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "youtu.be/Cqer4ApweVM") == "Cqer4ApweVM")
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "https://www.corememory.com/p/hes-here-to-end-death") == nil)
        #expect(MCPDataStore.youtubeVideoID(fromArgument: "not a video") == nil)
    }

    @Test("YouTube recovery starts automatically only for terminal podcast failures")
    func automaticYouTubeRecoveryPolicy() {
        var episode = makeEpisode(id: "youtube-auto", show: "Mind & Matter")
        episode.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage

        #expect(StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: true))
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: false))

        episode.errorMessage = StudioViewModel.retryablePodcastTranscriptMessage
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(episode, isYouTubeSignedIn: true))

        var article = makeArticle(
            url: "https://example.com/story",
            title: "Story",
            sourceType: .article
        )
        article.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage
        #expect(!StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(article, isYouTubeSignedIn: true))
    }
}
