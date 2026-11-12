import Testing
import Foundation
@testable import ForeverLM

/// One Substack post, reached by the reader's app link and by its own address,
/// is one source.
@Suite("Substack app links")
struct SubstackAppLinkTests {
    private let appLink = "https://substack.com/home/post/p-194171938"
    private let postAddress = "https://lettersfromthelab.substack.com/p/metabolism-as-inference"

    @Test("the reader's and the app's links to a post are app links", arguments: [
        "https://substack.com/home/post/p-194171938",
        "https://substack.com/home/post/p-196262908?source=queue",
        "https://substack.com/home/post/p-183478509#footnote-2-183478509",
        "https://substack.com/inbox/post/183002965",
        "https://www.substack.com/inbox/post/181502671?r=abc&utm_medium=ios&triedRedirect=true",
        "https://substack.com/@somewriter/p-213699661",
        "https://open.substack.com/pub/somepub/p/the-antibody-revolution?utm_campaign=posts-open-in-app",
    ])
    func recognisesAppLinks(address: String) {
        #expect(SubstackAppLink.isAppLink(address))
    }

    @Test("a post's own address, a note and a profile are not app links", arguments: [
        "https://lettersfromthelab.substack.com/p/metabolism-as-inference",
        "https://substack.com/@somewriter/note/c-286231404",
        "https://substack.com/@somewriter",
        "https://substack.com/home",
        "https://substack.com/home/post/p-",
        "https://substack.com/inbox/post/p-12",
        "https://example.com/home/post/p-194171938",
        "substack.com/home/post/p-194171938",
    ])
    func leavesOtherAddressesAlone(address: String) {
        #expect(!SubstackAppLink.isAppLink(address))
    }

    @Test("the address that answered an app link gives the post's own address")
    func readsThePostAddressFromTheAnswer() throws {
        #expect(SubstackAppLink.postAddress(
            answering: try #require(URL(string: "https://lettersfromthelab.substack.com/p/metabolism-as-inference?triedRedirect=true"))
        ) == postAddress)
        #expect(SubstackAppLink.postAddress(
            answering: try #require(URL(string: "https://www.ownpublication.example/p/a-post#footnote-1"))
        ) == "https://www.ownpublication.example/p/a-post")
        // Substack kept the request on its own pages, or sent it to something that is no post.
        #expect(SubstackAppLink.postAddress(answering: try #require(URL(string: appLink))) == nil)
        #expect(SubstackAppLink.postAddress(answering: try #require(URL(string: "https://substack.com/sign-in"))) == nil)
        #expect(SubstackAppLink.postAddress(answering: try #require(URL(string: "https://lettersfromthelab.substack.com/"))) == nil)
    }

    @Test("a page that forwards the browser to the post names the post's own address")
    func readsThePostAddressFromAForwardingPage() {
        let page = """
            <head><noscript><META http-equiv="refresh" content="0;URL=https://lettersfromthelab.substack.com/p/metabolism-as-inference?triedRedirect=true"></noscript>\
            <title>https://lettersfromthelab.substack.com/p/metabolism-as-inference?triedRedirect=true</title></head>
            """
        #expect(SubstackAppLink.postAddress(inForwardingPage: page) == postAddress)
        #expect(SubstackAppLink.postAddress(inForwardingPage: "<html><head><title>Sign in</title></head></html>") == nil)
        #expect(SubstackAppLink.postAddress(
            inForwardingPage: #"<meta http-equiv="refresh" content="0;URL=https://substack.com/sign-in">"#
        ) == nil)
    }

    @Test("a post saved under its own address is found by the app link, and learns it")
    func appLinkFindsThePostSavedUnderItsOwnAddress() throws {
        let store = try TestStores.inMemory()
        var saved = StudioArticle(url: postAddress, title: "Metabolism as Inference", sourceType: .article)
        #expect(try store.insertSourceIfNew(&saved))

        // The reader offers the app link: filed under the post's address, with the link as one more key.
        var offered = StudioArticle(url: appLink, title: "Metabolism as Inference", sourceType: .article)
            .readdressed(to: postAddress)
        #expect(offered.id == saved.id)
        #expect(try !store.insertSourceIfNew(&offered, alsoAt: [appLink]))
        #expect(try store.loadSources().count == 1)

        // The next reading-list pass does not offer the link again.
        let again = StudioArticle(url: appLink, title: "Metabolism as Inference", sourceType: .article)
        #expect(try store.newSourceCandidates(from: [again]).isEmpty)
        var direct = again
        #expect(try !store.insertSourceIfNew(&direct))
        #expect(try store.loadSources().count == 1)
    }

    @Test("a new post from an app link is saved under its own address and holds both")
    func newPostIsFiledUnderItsOwnAddress() throws {
        let store = try TestStores.inMemory()
        var offered = StudioArticle(url: appLink, title: "Metabolism as Inference", sourceType: .article)
            .readdressed(to: postAddress)
        #expect(try store.insertSourceIfNew(&offered, alsoAt: [appLink]))
        #expect(try store.loadSources().map(\.url) == [postAddress])

        var fromTheSite = StudioArticle(url: postAddress, sourceType: .article)
        #expect(try !store.insertSourceIfNew(&fromTheSite))
        var fromTheReader = StudioArticle(url: appLink, sourceType: .article)
        #expect(try !store.insertSourceIfNew(&fromTheReader))
        #expect(try store.loadSources().count == 1)
    }

    @Test("a source saved under an app link learns its post address, and the post is then no new source")
    func savedAppLinkSourceLearnsItsPostAddress() throws {
        let store = try TestStores.inMemory()
        var old = StudioArticle(url: appLink, title: "Metabolism as Inference - Letters", sourceType: .article)
        #expect(try store.insertSourceIfNew(&old))
        var note = StudioArticle(url: "https://substack.com/@somewriter/note/c-286231404", sourceType: .article)
        #expect(try store.insertSourceIfNew(&note))
        var elsewhere = StudioArticle(url: "https://example.com/an-article", sourceType: .article)
        #expect(try store.insertSourceIfNew(&elsewhere))

        let pending = try store.substackAppLinkSourcesWithoutPostAddress()
        #expect(pending.map(\.id) == [old.id])
        #expect(pending.map(\.url) == [appLink])

        try store.addAddress(postAddress, toSource: old.id)
        #expect(try store.substackAppLinkSourcesWithoutPostAddress().isEmpty)

        var fromTheSite = StudioArticle(url: postAddress, title: "Metabolism as Inference", sourceType: .article)
        #expect(try !store.insertSourceIfNew(&fromTheSite))
        #expect(fromTheSite.id == old.id)
        #expect(try store.loadSources().count == 3)
    }

    @Test("discovered app links are filed under the post's address; one post offered twice is one candidate")
    func discoveredAppLinksAreRefiled() async {
        let other = "https://substack.com/inbox/post/194171938"
        let unanswered = "https://substack.com/home/post/p-1"
        var first = StudioArticle(url: appLink, title: "Metabolism as Inference", sourceType: .article, discoveryOrigin: .safari)
        first.readAt = Date(timeIntervalSince1970: 1_700_000_000)
        first.dateAdded = Date(timeIntervalSince1970: 1_600_000_000)
        var candidates = [
            first,
            StudioArticle(url: "https://example.com/an-article", title: "An article", sourceType: .article),
            StudioArticle(url: other, title: "Metabolism as Inference", sourceType: .article, discoveryOrigin: .safari),
            StudioArticle(url: unanswered, title: "Gone", sourceType: .article),
        ]
        let answers = [appLink: postAddress, other: postAddress]

        let appLinks = await StudioViewModel.filingSubstackPostsUnderTheirOwnAddress(&candidates) { answers[$0] }

        #expect(candidates.map(\.url) == [postAddress, "https://example.com/an-article", unanswered])
        let filed = candidates[0]
        #expect(filed.id == SourceIdentity.stableID(for: postAddress))
        #expect(filed.title == "Metabolism as Inference")
        #expect(filed.domain == "lettersfromthelab.substack.com")
        #expect(filed.discoveryOrigin == .safari)
        #expect(filed.readAt == first.readAt)
        #expect(filed.dateAdded == first.dateAdded)
        #expect(appLinks == [filed.id: [appLink, other]])
    }

    @Test("a link typed without a title takes the post's host as its placeholder title")
    func placeholderTitleFollowsTheAddress() {
        let typed = StudioArticle(url: appLink, title: "substack.com", sourceType: .article)
        #expect(typed.readdressed(to: postAddress).title == "lettersfromthelab.substack.com")
    }
}
