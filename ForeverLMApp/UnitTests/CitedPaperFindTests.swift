import Foundation
import Testing
@testable import ForeverLM

/// "Find" on a cited paper with no matching record: the slide is read again for what it
/// prints about the paper, and that read has to land on the right row.
@Suite("Cited paper find")
struct CitedPaperFindTests {
    private typealias Citation = SlideCitationService.ExtractedCitation

    private func szetoRow() -> VideoCitedPaper {
        VideoCitedPaper(
            sourceID: "lecture",
            title: VideoCitedPaper.attributionLabel(authors: "Szeto", journal: "Br J Pharmacol", year: "2014"),
            authors: "Szeto",
            year: "2014",
            journal: "Br J Pharmacol",
            slideImagePath: "slides/12.jpg",
            status: .unresolved
        )
    }

    @Test("A slide read keeps the printed volume and pages, numbers or strings")
    func slideReadKeepsLocator() throws {
        let reply = """
        {"citations": [{"authors": "Szeto", "year": 2014, "journal": "Br J Pharmacol", \
        "volume": 171, "pages": "2029-50"}]}
        """
        let citation = try #require(try SlideCitationService.decodeReply(reply).citations.first)
        #expect(citation.year == "2014")
        #expect(citation.volume == "171")
        let locator = try #require(
            SlideCitationService.BibliographicLocator(volume: citation.volume, pages: citation.pages)
        )
        #expect(locator.volume == "171")
        #expect(locator.firstPage == "2029")
    }

    @Test("The re-read citation is matched to the row by first author and year")
    func matchesAttributionByAuthorAndYear() {
        let citations = [
            Citation(title: nil, authors: "Hayashida", year: "2023", journal: "BMC Medicine", doi: nil, url: nil),
            Citation(title: nil, authors: "Szeto HH", year: "2014", journal: "Br J Pharmacol", doi: nil, url: nil,
                     volume: "171", pages: "2029-50"),
        ]
        let matched = SlideCitationService.citation(matching: szetoRow(), in: citations)
        #expect(matched?.volume == "171")
    }

    @Test("Another paper on the slide is not taken for this one")
    func refusesADifferentPaper() {
        let citations = [
            Citation(title: nil, authors: "Hayashida", year: "2023", journal: "BMC Medicine", doi: nil, url: nil),
            Citation(title: nil, authors: "Paradies", year: "2014", journal: "BBA", doi: nil, url: nil),
        ]
        #expect(SlideCitationService.citation(matching: szetoRow(), in: citations) == nil)
    }

    @Test("A slide citing one paper answers for the row read off it")
    func singleCitationAnswers() {
        let only = Citation(title: nil, authors: "Szetto", year: "2014", journal: nil, doi: nil, url: nil)
        #expect(SlideCitationService.citation(matching: szetoRow(), in: [only])?.authors == "Szetto")
    }

    @Test("Merging fills gaps, keeps the row's id, and keeps an attribution an attribution")
    func mergingFillsGaps() {
        var row = szetoRow()
        row.journal = nil
        row.title = VideoCitedPaper.attributionLabel(authors: "Szeto", journal: nil, year: "2014")
        let reread = Citation(title: nil, authors: "Szeto", year: "2014", journal: "Br J Pharmacol",
                              doi: nil, url: nil, volume: "171", pages: "2029-50")

        let merged = SlideCitationService.merging(reread, into: row)
        #expect(merged.id == row.id)
        #expect(merged.journal == "Br J Pharmacol")
        #expect(merged.isAttributionOnly)
        #expect(merged.slideImagePath == row.slideImagePath)
    }

    @Test("A title printed on the re-read replaces the stand-in label")
    func mergingTakesPrintedTitle() {
        let reread = Citation(title: "First-in-class cardiolipin-protective compound", authors: "Szeto",
                              year: "2014", journal: "Br J Pharmacol", doi: nil, url: nil)
        let merged = SlideCitationService.merging(reread, into: szetoRow())
        #expect(merged.title == "First-in-class cardiolipin-protective compound")
        #expect(!merged.isAttributionOnly)
    }

    // MARK: - A bare venue reference

    /// The row a lecture slide left on 2026-09-27: "Selective detergents (PNAS,1980
    /// 77:3430-4)". The first read took the bullet for the title and dropped the volume and
    /// page, and the slide prints no author.
    private func detergentsRow(authors: String? = nil) -> VideoCitedPaper {
        VideoCitedPaper(
            sourceID: "lecture",
            title: "Selective detergents",
            authors: authors,
            year: "1980",
            journal: "PNAS",
            slideImagePath: "slides/slide_004_000520s.jpg",
            status: .unresolved
        )
    }

    /// The paper it cites, as Crossref holds it.
    private let fiskum = SlideCitationService.ResolvedPaper(
        doi: "10.1073/pnas.77.6.3430",
        title: "The cytoskeleton of digitonin-treated rat hepatocytes.",
        journal: "Proceedings of the National Academy of Sciences",
        year: "1980",
        authors: "Fiskum; Craig; Decker; Lehninger",
        volume: "77",
        firstPage: "3430",
        journalAliases: ["Proc. Natl. Acad. Sci. U.S.A."]
    )

    private func detergentsLocator() throws -> SlideCitationService.BibliographicLocator {
        try #require(SlideCitationService.BibliographicLocator(volume: "77", pages: "3430-4"))
    }

    @Test("A re-read citation is matched to a row with no author by its venue and year")
    func matchesAuthorlessRowByVenue() {
        let citations = [
            Citation(title: nil, authors: "Hayashida", year: "2023", journal: "BMC Medicine", doi: nil, url: nil),
            Citation(title: nil, authors: nil, year: "1980", journal: "PNAS", doi: nil, url: nil,
                     volume: "77", pages: "3430-4"),
        ]
        let matched = SlideCitationService.citation(matching: detergentsRow(), in: citations)
        #expect(matched?.volume == "77")
        #expect(matched?.pages == "3430-4")
    }

    @Test("The venue, volume and first page identify a paper when no author is printed")
    func venueLocatorIdentifiesPaper() throws {
        let row = detergentsRow()
        let locator = try detergentsLocator()
        #expect(SlideCitationService.venueLocatorAccepted(read: row, locator: locator, record: fiskum))

        func record(volume: String?, firstPage: String?, journal: String = "Proceedings of the National Academy of Sciences",
                    year: String = "1980") -> SlideCitationService.ResolvedPaper {
            SlideCitationService.ResolvedPaper(
                doi: "10.1000/other", title: "Another paper", journal: journal, year: year,
                authors: "Someone", volume: volume, firstPage: firstPage
            )
        }
        #expect(!SlideCitationService.venueLocatorAccepted(read: row, locator: locator, record: record(volume: "77", firstPage: "3431")))
        #expect(!SlideCitationService.venueLocatorAccepted(read: row, locator: locator, record: record(volume: "78", firstPage: "3430")))
        #expect(!SlideCitationService.venueLocatorAccepted(
            read: row, locator: locator, record: record(volume: "77", firstPage: "3430", journal: "Biochemistry")
        ))
        #expect(!SlideCitationService.venueLocatorAccepted(
            read: row, locator: locator, record: record(volume: "77", firstPage: "3430", year: "1983")
        ))
        // A field the record does not carry confirms nothing, and without an author both must.
        #expect(!SlideCitationService.venueLocatorAccepted(read: row, locator: locator, record: record(volume: "77", firstPage: nil)))
        let volumeOnly = try #require(SlideCitationService.BibliographicLocator(volume: "77", pages: nil))
        #expect(!SlideCitationService.venueLocatorAccepted(read: row, locator: volumeOnly, record: fiskum))
    }

    @Test("A bullet read as the title no longer turns the cited paper away")
    func webMatchTakesVenueLocatorOverBulletTitle() throws {
        let locator = try detergentsLocator()
        #expect(SlideCitationService.webMatchAccepted(read: detergentsRow(), candidate: fiskum, locator: locator))
        // Without the volume and page, a title that is not the paper's still rejects it.
        #expect(!SlideCitationService.webMatchAccepted(read: detergentsRow(), candidate: fiskum))
        // A printed author still has to be on the record.
        #expect(!SlideCitationService.webMatchAccepted(
            read: detergentsRow(authors: "Smith"), candidate: fiskum, locator: locator
        ))
        #expect(SlideCitationService.webMatchAccepted(
            read: detergentsRow(authors: "Fiskum"), candidate: fiskum, locator: locator
        ))
    }

    @Test("The card takes the paper's title when the slide's words were not it")
    func resolvedTitle() {
        #expect(SlideCitationService.title(
            of: detergentsRow(), identifiedAs: fiskum, wasAttributionOnly: false
        ) == fiskum.title)

        // A printed title with an author beside it stays as it was read.
        let titled = VideoCitedPaper(
            sourceID: "lecture", title: "Cytoskeleton of digitonin-treated hepatocytes",
            authors: "Fiskum", year: "1980", journal: "PNAS", status: .unresolved
        )
        #expect(SlideCitationService.title(of: titled, identifiedAs: fiskum, wasAttributionOnly: false) == titled.title)

        let matching = VideoCitedPaper(
            sourceID: "lecture", title: "The cytoskeleton of digitonin treated rat hepatocytes",
            year: "1980", journal: "PNAS", status: .unresolved
        )
        #expect(SlideCitationService.title(of: matching, identifiedAs: fiskum, wasAttributionOnly: false) == matching.title)
        #expect(SlideCitationService.title(of: szetoRow(), identifiedAs: fiskum, wasAttributionOnly: true) == fiskum.title)
    }

    @Test("A bare venue reference is kept, under its venue, and two of them stay apart")
    func bareVenueReferenceIsKept() {
        let citations = [
            Citation(title: nil, authors: nil, year: "1980", journal: "PNAS", doi: nil, url: nil,
                     volume: "77", pages: "3430-4"),
            Citation(title: nil, authors: nil, year: "1980", journal: "PNAS", doi: nil, url: nil,
                     volume: "77", pages: "1234-8"),
            // A venue and a year name no paper.
            Citation(title: nil, authors: nil, year: "1980", journal: "PNAS", doi: nil, url: nil),
        ]
        let (candidates, locators) = SlideCitationService.candidatesAndLocators(
            citations, sourceID: "lecture", sourceText: "Selective detergents (PNAS,1980 77:3430-4)"
        )
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.title == "PNAS, 1980" && $0.isAttributionOnly })
        #expect(candidates.allSatisfy { $0.displaySubtitle == nil })
        #expect(locators[candidates[0].id]?.firstPage == "3430")
        #expect(locators[candidates[1].id]?.firstPage == "1234")
    }

    @Test("A credit with no author leads with its venue")
    func authorlessLabel() {
        #expect(VideoCitedPaper.attributionLabel(authors: nil, journal: "PNAS", year: "1980") == "PNAS, 1980")
        #expect(VideoCitedPaper.attributionLabel(authors: nil, journal: nil, year: nil) == "Cited paper")
        #expect(VideoCitedPaper.attributionLabel(authors: "Szeto", journal: nil, year: "2014") == "Szeto et al., 2014")
    }

    @Test("A volume handed over inside the pages is read from before the colon")
    func locatorSplitsVolumeFromPages() throws {
        let colon = try #require(SlideCitationService.BibliographicLocator(volume: nil, pages: "77:3430-4"))
        #expect(colon.volume == "77")
        #expect(colon.firstPage == "3430")
        let issue = try #require(SlideCitationService.BibliographicLocator(volume: nil, pages: "171(8):2029-50"))
        #expect(issue.volume == "171")
        #expect(issue.firstPage == "2029")
        let supplement = try #require(SlideCitationService.BibliographicLocator(volume: nil, pages: "S1:23"))
        #expect(supplement.volume == nil)
        // A printed volume is never second-guessed.
        let printed = try #require(SlideCitationService.BibliographicLocator(volume: "12", pages: "77:3430"))
        #expect(printed.volume == "12")
    }

    @Test("A slide read that is not citation JSON moves on to the next backup model")
    func unusableSlideReadTriesBackup() {
        #expect(AIBackupModels.shouldTryBackup(after: SlideCitationService.SlideCitationError.malformedResponse))
        #expect(throws: SlideCitationService.SlideCitationError.self) {
            _ = try SlideCitationService.decodeReply("User Safety: safe")
        }
    }
}

/// A reply the work cannot use — a safety classifier's verdict where a slide's citations
/// were asked for — is no answer: it is thrown, never kept, and a kept one is asked for
/// again rather than replayed.
@Suite("Unusable AI replies", .serialized)
struct UnusableAIReplyTests {
    private static let unusable = "User Safety: safe"
    private static let usable = #"{"citations": []}"#
    private let validate: @Sendable (String) throws -> Void = { _ = try SlideCitationService.decodeReply($0) }

    private func makeService() throws -> (AIService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-unusable-reply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = AIService(
            session: UnusableReplyStubURLProtocol.mockSession(),
            responseCacheStorage: StorageService(storeRoot: root)
        )
        return (service, root)
    }

    /// Labelled so the reply may be cached, and with a label no task has, so no backup
    /// models are read from this Mac's settings.
    private var config: AITaskConfig {
        var config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        config.taskLabel = "unusable_reply_test"
        return config
    }

    private func read(_ service: AIService, checked: Bool) async throws -> String {
        try await service.call(
            config: config, system: "Read the slide.", user: "Slide 4.", maxTokens: 60,
            validateResponse: checked ? validate : nil
        )
    }

    @Test("An unusable reply is thrown and never kept; a usable one is kept as before")
    func unusableReplyIsNotKept() async throws {
        UnusableReplyStubURLProtocol.reset(replies: [Self.unusable, Self.usable])
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: SlideCitationService.SlideCitationError.self) {
            _ = try await read(service, checked: true)
        }
        #expect(try await read(service, checked: true) == Self.usable)
        #expect(UnusableReplyStubURLProtocol.requestCount() == 2, "the unusable reply was asked for again")
        #expect(try await read(service, checked: true) == Self.usable)
        #expect(UnusableReplyStubURLProtocol.requestCount() == 2, "the usable reply came from the cache")
    }

    @Test("A kept reply its work cannot use is asked for again, not replayed")
    func keptUnusableReplyIsAskedAgain() async throws {
        UnusableReplyStubURLProtocol.reset(replies: [Self.unusable, Self.usable])
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }

        // Kept by a call that did not check it, as every reply was before replies were checked.
        #expect(try await read(service, checked: false) == Self.unusable)
        #expect(try await read(service, checked: true) == Self.usable)
        #expect(UnusableReplyStubURLProtocol.requestCount() == 2)
    }
}

/// Answers every request with the next reply in its queue, in the shape the request's
/// provider path expects, and counts the requests.
final class UnusableReplyStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String] = []
    nonisolated(unsafe) private static var requests = 0

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnusableReplyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(replies: [String]) {
        lock.lock(); self.replies = replies; requests = 0; lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    // Every request this session makes is answered here; none reaches a network.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let text = Self.replies.isEmpty ? "" : Self.replies.removeFirst()
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let escaped = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let body: String
        if url.path.contains("/anthropic/") {
            body = #"{"content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":10,"output_tokens":10}}"#
        } else {
            body = #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":10,"completion_tokens":10}}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
