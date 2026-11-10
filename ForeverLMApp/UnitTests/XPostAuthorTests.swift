import Testing
import Foundation
import SQLite3
@testable import ForeverLM

// MARK: - Helpers

@MainActor
private func makeViewModel() -> StudioViewModel {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("XPostAuthorTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let service = StorageService(storeRoot: tmp)
    return StudioViewModel(storageService: service)
}

@MainActor
private func makeXPost(
    username: String,
    tweetID: String = "1",
    text: String = "Learning biotech, part 4",
    author: String?
) -> StudioArticle {
    var article = StudioArticle(
        url: "https://x.com/\(username)/status/\(tweetID)",
        title: "@\(username): \(text)",
        sourceType: .xPost,
        discoveryOrigin: .xBookmarks
    )
    article.domain = "x.com"
    article.content = text
    article.state = .ready
    article.author = author
    return article
}

// MARK: - Tests

@Suite("X post authors")
@MainActor
struct XPostAuthorTests {

    @Test("A post URL names the handle that wrote it")
    func usernameFromPostURL() {
        #expect(
            StudioViewModel.xPostUsername(inURL: "https://x.com/MartinBJensen/status/1889") == "MartinBJensen"
        )
        #expect(
            StudioViewModel.xPostUsername(inURL: "https://twitter.com/owl_posting/status/42") == "owl_posting"
        )
    }

    @Test("URLs that name no author resolve to no handle")
    func noUsernameWhereThereIsNone() {
        // X's own anonymous post form carries no author.
        #expect(StudioViewModel.xPostUsername(inURL: "https://x.com/i/status/1889") == nil)
        #expect(StudioViewModel.xPostUsername(inURL: "https://x.com/MartinBJensen") == nil)
        #expect(StudioViewModel.xPostUsername(inURL: "https://example.com/a/status/1") == nil)
        #expect(StudioViewModel.xPostUsername(inURL: "not a url") == nil)
    }

    @Test("A blank or placeholder display name is no author at all")
    func placeholderAuthorNamesRejected() {
        #expect(StudioViewModel.normalizedXAuthorName("  Martin Borch Jensen ") == "Martin Borch Jensen")
        #expect(StudioViewModel.normalizedXAuthorName("   ") == nil)
        // What the fetch falls back to when X returns no user record.
        #expect(StudioViewModel.normalizedXAuthorName("Unknown") == nil)
    }

    @Test("A saved display name finds the post the handle would hide")
    func searchFindsPostByDisplayName() async {
        let vm = makeViewModel()
        vm.articles = [makeXPost(username: "MartinBJensen", author: "Martin Borch Jensen")]

        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "Martin Borch Jensen").count == 1)
        // The handle keeps working: it is still the title and the URL.
        #expect(index.rows(matching: "martinbjensen").count == 1)
        #expect(index.rows(matching: "Philip Ball").isEmpty)
    }

    @Test("Only a post with no picture of its own is worth a lookup")
    func picturedPostsAreNotCandidates() async {
        let vm = makeViewModel()
        var pictured = makeXPost(username: "MartinBJensen", tweetID: "1", author: "Martin Borch Jensen")
        pictured.artworkURL = "https://pbs.twimg.com/profile_images/9/mbj_400x400.jpg"
        var article = StudioArticle(url: "https://example.com/essay", title: "An essay")
        article.state = .ready
        vm.articles = [pictured, article]

        // Nothing to look up, so the pass answers without reaching X at all —
        // which is what makes it safe to run from every row that appears.
        #expect(await vm.backfillXPostArtwork() == 0)
        #expect(vm.articles[0].artworkURL == "https://pbs.twimg.com/profile_images/9/mbj_400x400.jpg")
        #expect(vm.articles[1].artworkURL == nil)
    }

    @Test("A post that knows only its handle is what the backfill looks for")
    func unnamedPostsAreTheBackfillCandidates() async {
        let vm = makeViewModel()
        vm.articles = [makeXPost(username: "MartinBJensen", author: nil)]

        // The name search cannot answer until the display name is saved.
        let index = await vm.artifactSourcePickerIndex()
        #expect(index.rows(matching: "Martin Borch Jensen").isEmpty)
        #expect(index.rows(matching: "martinbjensen").count == 1)
    }
}

// MARK: - Persistence

@Suite("X post author persistence")
@MainActor
struct XPostAuthorPersistenceTests {

    /// The bug this guards against: the author backfill looked up 71 display
    /// names and "saved" them on every plugin sync, but the x_posts upsert
    /// had no column for the name and the projection never read one, so every
    /// reload forgot the names and the next sync named the same 71 posts again.
    @Test("A saved display name survives a reload")
    func authorSurvivesReload() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("XPostAuthorPersistence_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)

        var post = makeXPost(username: "MartinBJensen", author: nil)
        try await service.saveSource(post)
        var loaded = try await service.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].author == nil)

        // What the backfill does once it has the name.
        post.author = StudioViewModel.normalizedXAuthorName("Martin Borch Jensen")
        try await service.saveSource(post)
        loaded = try await service.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].author == "Martin Borch Jensen")
    }
}
