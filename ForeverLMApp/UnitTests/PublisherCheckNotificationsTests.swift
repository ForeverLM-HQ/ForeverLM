import Foundation
import Testing
@testable import ForeverLM

/// A publisher check is a notification whose click opens the paper's page in
/// the Browser; these pin what it says, how it is keyed, and setup's hold.
@MainActor
struct PublisherCheckNotificationsTests {
    @Test("the same paper's page keys one notification, however its URL is written")
    func oneNotificationPerPage() throws {
        let a = try #require(URL(string: "https://www.sciencedirect.com/science/article/pii/S0092867424001234"))
        let b = try #require(URL(string: "https://www.sciencedirect.com/science/article/pii/S0092867424001234/"))
        let other = try #require(URL(string: "https://www.sciencedirect.com/science/article/pii/S0092867424009999"))

        #expect(PublisherCheckNotifications.identifier(for: a) == PublisherCheckNotifications.identifier(for: b))
        #expect(PublisherCheckNotifications.identifier(for: a) != PublisherCheckNotifications.identifier(for: other))
        #expect(PublisherCheckNotifications.identifier(for: a).hasPrefix(PublisherCheckNotifications.identifierPrefix))
    }

    @Test("the notification names the publisher and the paper")
    func wording() {
        #expect(PublisherCheckNotifications.title(publisher: "ScienceDirect") == "ScienceDirect wants to check you're human")
        #expect(PublisherCheckNotifications.body(paperTitle: "Mitochondrial transfer").hasPrefix("Mitochondrial transfer is waiting for its PDF."))
        #expect(PublisherCheckNotifications.body(paperTitle: "  ").hasPrefix("A paper is waiting for its PDF."))
        #expect(PublisherCheckNotifications.body(paperTitle: nil).contains("in the Browser"))
    }

    @Test("setup's hold keeps checks quiet until it runs out")
    func holdRunsOut() {
        let now = Date()
        PublisherCheckNotifications.hold(for: .seconds(600), now: now)
        #expect(PublisherCheckNotifications.isHeld(now: now.addingTimeInterval(599)))
        #expect(!PublisherCheckNotifications.isHeld(now: now.addingTimeInterval(601)))
        // Leave no hold behind for other tests.
        PublisherCheckNotifications.hold(for: .zero, now: now.addingTimeInterval(-1))
    }

    @Test("the AI browser names a publisher by its host")
    func publisherName() throws {
        let cell = try #require(URL(string: "https://www.cell.com/cell/fulltext/S0092-8674(24)00123-4"))
        let nature = try #require(URL(string: "https://nature.com/articles/s41586-024-00001-1"))
        #expect(SourceDiscovery.PaperAIBrowserDownloadService.publisherName(for: cell) == "cell.com")
        #expect(SourceDiscovery.PaperAIBrowserDownloadService.publisherName(for: nature) == "nature.com")
    }
}
