import Foundation
import Testing
@testable import ForeverLM

/// A podcast episode found for a source waits for Confirm, the reader's or
/// resolve_podcast_match's. The match has no column, so the source's row
/// loses it when it is read back from the store; on 2026-10-02 a CloudKit
/// refresh between find_podcast_match and resolve_podcast_match left the
/// BiotechTV row asking to confirm nothing.
@Suite("Staged podcast match")
@MainActor
struct StagedPodcastMatchTests {
    private func makeViewModel() -> StudioViewModel {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StagedPodcastMatchTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: tmp))
    }

    private let match = PodcastFinderService.PodcastMatch(
        podcastName: "BiotechTV - News",
        episodeTitle: "Roche will pay Manifold Bio $55M up front",
        applePodcastsURL: "https://podcasts.apple.com/us/podcast/roche/id1796836887?i=1000735033082",
        artworkURL: nil,
        storeTrackId: 1_000_735_033_082
    )

    @Test("A staged match outlives the row being read back from the store, and Reject clears it")
    func survivesReload() async {
        let vm = makeViewModel()
        let article = StudioArticle(url: "https://example.com/roche-manifold", title: "Roche and Manifold Bio", sourceType: .podcast)
        vm.articles = [article]

        let offer = await vm.offerPodcastMatch(match, for: article.id, confirmingAtOnce: false)
        #expect(offer == .awaitingConfirmation)

        // What a CloudKit refresh puts back: the row without the match.
        var reloaded = vm.articles[0]
        reloaded.podcastMatch = nil
        reloaded.podcastMatchTrackId = nil
        vm.articles[0] = reloaded

        let held = vm.heldPodcastMatch(for: article.id)
        #expect(held?.info.episodeTitle == "Roche will pay Manifold Bio $55M up front")
        #expect(held?.trackId == 1_000_735_033_082)

        await vm.rejectPodcastMatch(for: article.id)
        #expect(vm.heldPodcastMatch(for: article.id) == nil)
        #expect(vm.articles[0].state == .queued)
    }

    /// The 2026-10-02 case: an assistant added an Apple Podcasts episode over
    /// MCP with its page as content, and the confirmed row went ready on the
    /// page's 45 words of show notes under "podcasts.apple.com", no picture.
    private static let firstRounderPage = "https://podcasts.apple.com/us/podcast/first-rounder-john-maraganore/id562626393?i=1000437436419"
    private static let firstRounderArtwork = "https://is1-ssl.mzstatic.com/image/thumb/Podcasts126/v4/c1/fa/37/c1fa371b-d8e9-3cf6-0031-dd0ad2e0662e/mza_14851455372299837377.jpg/100x100bb.jpg"
    private let firstRounder = PodcastFinderService.PodcastMatch(
        podcastName: "First Rounders",
        episodeTitle: "First Rounder: John Maraganore",
        applePodcastsURL: StagedPodcastMatchTests.firstRounderPage,
        artworkURL: StagedPodcastMatchTests.firstRounderArtwork,
        storeTrackId: 1_000_437_436_419
    )
    private static let showNotes = "First Rounder: John Maraganore\n\n# First Rounder: John Maraganore\nJohn Maraganore is CEO of Alnylam Pharmaceuticals."

    private func storedRow(_ vm: StudioViewModel, _ id: String) async throws -> StudioArticle? {
        try await vm.storage.loadSourcesForExport(sourceIDs: [id]).first
    }

    @Test("A confirmed episode filed under its page leaves the page's text behind and takes its show's name and picture")
    func confirmedPageRowDropsPageText() async throws {
        let vm = makeViewModel()
        var article = StudioArticle(url: Self.firstRounderPage, title: "podcasts.apple.com", sourceType: .podcast)
        article.domain = "podcasts.apple.com"
        article.content = Self.showNotes
        article.state = .ready
        #expect(try await vm.storage.insertSourceIfNew(&article))
        try await vm.storage.saveSource(article)
        #expect(await vm.storage.loadSourceContent(article.id) == Self.showNotes)
        vm.articles = [article]

        let offer = await vm.offerPodcastMatch(firstRounder, for: article.id, confirmingAtOnce: false)
        #expect(offer == .awaitingConfirmation)
        let held = try #require(vm.heldPodcastMatch(for: article.id))
        #expect(held.artworkURL == Self.firstRounderArtwork)

        #expect(await vm.placeConfirmedPodcastEpisode(article.id, held: held))
        // What `confirmPodcastMatch` saves next must not bring the page back.
        try await vm.storage.saveSource(vm.articles[0])

        #expect(await vm.storage.loadSourceContent(article.id) == nil)
        let stored = try #require(try await storedRow(vm, article.id))
        #expect(stored.url == "apple-podcast://episode/1000437436419")
        #expect(stored.title == "First Rounder: John Maraganore")
        #expect(stored.domain == "First Rounders")
        #expect(stored.artworkURL == Self.firstRounderArtwork)
        #expect(stored.podcastWebPageURL == Self.firstRounderPage)
        #expect(vm.articles[0].content == nil)
        // The transcript fetch now has nothing to mistake for a transcript.
        #expect(vm.podcastHydrationCandidate(for: article.id)?.podcastName == "First Rounders")
    }

    @Test("A video matched to its episode keeps its captions")
    func confirmedVideoKeepsCaptions() async throws {
        let vm = makeViewModel()
        let captions = "Welcome back. Today John Maraganore tells us how Alnylam started."
        var article = StudioArticle(url: "https://www.youtube.com/watch?v=abcdefghijk", title: "First Rounder: John Maraganore", sourceType: .video)
        article.content = captions
        article.state = .ready
        #expect(try await vm.storage.insertSourceIfNew(&article))
        try await vm.storage.saveSource(article)
        vm.articles = [article]

        await vm.offerPodcastMatch(firstRounder, for: article.id, confirmingAtOnce: false)
        let held = try #require(vm.heldPodcastMatch(for: article.id))
        #expect(await vm.placeConfirmedPodcastEpisode(article.id, held: held))
        try await vm.storage.saveSource(vm.articles[0])

        #expect(await vm.storage.loadSourceContent(article.id) == captions)
        #expect(vm.articles[0].url == "apple-podcast://episode/1000437436419")
        #expect(vm.articles[0].domain == "First Rounders")
    }

    @Test("An episode another source already is stays where it is and says so")
    func confirmedPageRowThatIsAlreadyHeld() async throws {
        let vm = makeViewModel()
        var held = StudioArticle(url: "apple-podcast://episode/1000437436419", title: "John Maraganore on Biogen and Alnylam", sourceType: .podcast)
        held.domain = "First Rounders"
        #expect(try await vm.storage.insertSourceIfNew(&held))
        var article = StudioArticle(url: Self.firstRounderPage, title: "podcasts.apple.com", sourceType: .podcast)
        article.domain = "podcasts.apple.com"
        #expect(try await vm.storage.insertSourceIfNew(&article))
        vm.articles = [held, article]

        await vm.offerPodcastMatch(firstRounder, for: article.id, confirmingAtOnce: false)
        let staged = try #require(vm.heldPodcastMatch(for: article.id))
        #expect(await vm.placeConfirmedPodcastEpisode(article.id, held: staged) == false)

        let row = try #require(vm.articles.first(where: { $0.id == article.id }))
        #expect(row.state == .error)
        #expect(row.errorMessage == "Already in your sources: \"John Maraganore on Biogen and Alnylam\"")
        #expect(try await storedRow(vm, article.id)?.url == Self.firstRounderPage)
    }

    @Test("A row that still holds its match is read as before")
    func rowHeldMatch() {
        let vm = makeViewModel()
        var article = StudioArticle(url: "https://example.com/episode", title: "An episode", sourceType: .podcast)
        article.podcastMatch = PodcastMatchInfo(podcastName: "Show", episodeTitle: "An episode", applePodcastsURL: "https://podcasts.apple.com/us/podcast/x/id1?i=1")
        article.podcastMatchTrackId = 1
        vm.articles = [article]
        #expect(vm.heldPodcastMatch(for: article.id)?.trackId == 1)
        #expect(vm.heldPodcastMatch(for: "another") == nil)
    }
}
