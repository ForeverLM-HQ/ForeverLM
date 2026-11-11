import Foundation
import Testing
@testable import ForeverLM

/// Discover, in a notebook's Add sources (product owner, 2026-09-30, pointing at
/// Gemini Notebook's Source Discovery): one web search judges fit and writes a
/// line on why; ForeverLM owns identity — an address is listed only when the
/// engine cited it, Crossref knows its DOI, or the page opens, and its kind is
/// read off the URL. Papers mode is PubMed, free. Nothing here reaches the
/// network or a model: every outside call is a stub.
@Suite("Source Discovery")
struct WebSourceDiscoveryTests {

    /// What the stubs were asked, so a refusal can be shown to have sent nothing.
    actor CallLog {
        private(set) var requests: [WebSourceDiscovery.SearchRequest] = []
        private(set) var openedPages: [String] = []
        private(set) var crossrefDOIs: [String] = []

        var searches: Int { requests.count }

        func noteSearch(_ request: WebSourceDiscovery.SearchRequest) { requests.append(request) }
        func noteOpened(_ url: String) { openedPages.append(url) }
        func noteCrossref(_ doi: String) { crossrefDOIs.append(doi) }
    }

    static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "anthropic/claude-sonnet-5")

    static func dependencies(
        log: CallLog,
        webAvailable: Bool = true,
        reply: String = #"{"summary": "", "sources": []}"#,
        citations: [AIWebCitation] = [],
        crossrefTitles: [String: String] = [:],
        openingPages: Set<String> = [],
        pageTitles: [String: String] = [:]
    ) -> WebSourceDiscovery.Dependencies {
        WebSourceDiscovery.Dependencies(
            webSearchIsAvailable: { _ in webAvailable },
            search: { _, request in
                await log.noteSearch(request)
                return WebSourceDiscovery.SearchReply(text: reply, citations: citations)
            },
            crossrefTitle: { doi in
                await log.noteCrossref(doi)
                return crossrefTitles[doi]
            },
            pageOpens: { url in
                await log.noteOpened(url)
                guard openingPages.contains(url) else { return nil }
                return WebPageReader.Opening(finalURL: url, title: pageTitles[url])
            }
        )
    }

    /// A search that answers in turn: a reply, or a cut-off stream.
    actor SearchScript {
        enum Step: Sendable {
            case reply(String)
            case cutOff
        }

        private var steps: [Step]
        private(set) var budgets: [Int] = []

        init(_ steps: [Step]) { self.steps = steps }

        func next(_ request: WebSourceDiscovery.SearchRequest) throws -> String {
            budgets.append(request.maxTokens)
            let step = steps.isEmpty ? Step.reply("") : steps.removeFirst()
            switch step {
            case .reply(let text): return text
            case .cutOff: throw AIError.outputTokenLimit("The answer reached its length limit.")
            }
        }
    }

    static func scripted(_ script: SearchScript) -> WebSourceDiscovery.Dependencies {
        WebSourceDiscovery.Dependencies(
            webSearchIsAvailable: { _ in true },
            search: { _, request in
                let text = try await script.next(request)
                return WebSourceDiscovery.SearchReply(text: text, citations: [])
            },
            crossrefTitle: { _ in nil },
            pageOpens: { _ in nil }
        )
    }

    // MARK: - The task

    @Test("Source Discovery is a chat-route task the learner starts, priced on the chat's model")
    func taskContract() {
        let task = AITask.sourceDiscovery
        #expect(task.rawValue == "source_discovery")
        #expect(task.followsChatRoute)
        #expect(!task.usesBackgroundModelDefault)
        #expect(!task.isBackgroundWork)
        #expect(task.qualificationRole == .chat)
        #expect(!task.requiresVision)
        #expect(task.defaultPrompt == Prompts.sourceDiscovery)
        let descriptor = AITaskSettingsCatalog.descriptor(forRawID: "source_discovery")
        #expect(descriptor?.displayName == "Source Discovery")
        #expect(descriptor?.modelDefault == .chat)
        #expect(AIUsageTaskLabel.text(for: "source_discovery") == "Discover Sources")
        // It runs on the chat's model, so on the host the learner chose for it.
        #expect(AIService.openRouterHostSlots(forTaskLabel: task.rawValue) == ["chat"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: AITask.deepResearch.rawValue) == ["chat"])
        // The chat route has no backup chain: one model answers.
        #expect(AIBackupModels.slot(for: task) == nil)
    }

    // MARK: - Reading the answer

    @Test("The reply decodes through code fences, drops what is not a web page, and keeps one row per page")
    func decodesReply() throws {
        let reply = """
        ```json
        {"summary": "Three angles on NAD+ decline.", "sources": [
          {"url": "https://doi.org/10.1038/s41586-020-0001-1", "title": "A paper", "why": "It measures the decline.", "published": 2020},
          {"url": "ftp://example.org/file.txt", "title": "Not a web page"},
          {"url": "not a url", "title": "Nothing"},
          {"url": "https://dx.doi.org/10.1038/s41586-020-0001-1", "title": "The same paper by its DOI"},
          {"url": "https://www.example.org/essay/", "title": "An essay", "why": "It argues the other side.", "published": "2024-03-01"},
          {"url": "https://example.org/essay", "title": "The same essay"},
          {"url": "https://example.org/talk", "title": "A talk"},
          {"url": "https://example.org/fourth", "title": "Past the limit"}
        ]}
        ```
        """
        let decoded = try WebSourceDiscovery.decodeReply(reply, limit: 3)
        #expect(decoded.summary == "Three angles on NAD+ decline.")
        #expect(decoded.picks.map(\.url) == [
            "https://doi.org/10.1038/s41586-020-0001-1",
            "https://www.example.org/essay/",
            "https://example.org/talk",
        ])
        #expect(decoded.picks[0].published == "2020")
        #expect(decoded.picks[1].published == "2024-03-01")
        #expect(decoded.picks[1].why == "It argues the other side.")

        #expect(throws: WebSourceDiscoveryError.unreadableReply) {
            _ = try WebSourceDiscovery.decodeReply("I could not find anything useful.", limit: 10)
        }
        #expect(throws: WebSourceDiscoveryError.unreadableReply) {
            _ = try WebSourceDiscovery.decodeReply(#"{"summary": "no list"}"#, limit: 10)
        }
    }

    @Test("A work's kind is read off its address, never taken from the model")
    func kindComesFromTheURL() {
        #expect(WebSourceDiscovery.kind(of: "https://doi.org/10.1038/s41586-020-0001-1") == .paper)
        #expect(WebSourceDiscovery.kind(of: "https://www.youtube.com/watch?v=abc123def45") == .video)
        #expect(WebSourceDiscovery.kind(of: "https://example.substack.com/p/a-post") == .article)
        for url in ["https://pubmed.ncbi.nlm.nih.gov/42721963/", "https://podcasts.apple.com/us/podcast/x/id1?i=2"] {
            #expect(
                WebSourceDiscovery.kind(of: url)
                    == VideoCitedPaper.Kind(sourceType: StudioViewModel.detectSourceType(url: url))
            )
        }
    }

    // MARK: - Checking the addresses

    @Test("A pick stays only when the engine cited it, Crossref knows its DOI, or its page opens")
    func vettingKeepsOnlyRealAddresses() async throws {
        let log = CallLog()
        let picks = [
            WebSourceDiscovery.Pick(url: "https://example.org/cited/", title: "Cited", why: "w", published: nil),
            WebSourceDiscovery.Pick(url: "https://doi.org/10.1000/known", title: "Model's title", why: "w", published: nil),
            WebSourceDiscovery.Pick(url: "https://example.org/opens", title: "Opens", why: "w", published: nil),
            WebSourceDiscovery.Pick(url: "https://example.org/made-up-404", title: "Invented", why: "w", published: nil),
            WebSourceDiscovery.Pick(url: "https://doi.org/10.1000/unknown", title: "Unknown DOI, dead page", why: "w", published: nil),
            WebSourceDiscovery.Pick(url: "https://example.org/titled", title: "The model's name for it", why: "w", published: nil),
        ]
        let dependencies = Self.dependencies(
            log: log,
            crossrefTitles: ["10.1000/known": "Crossref's own title"],
            openingPages: ["https://example.org/opens", "https://example.org/titled"],
            pageTitles: ["https://example.org/titled": "  The page's own title "]
        )
        let vetting = await WebSourceDiscovery.vet(
            picks,
            citations: [AIWebCitation(url: "https://www.example.org/cited", title: "Cited")],
            dependencies: dependencies
        )
        #expect(vetting.kept.map(\.url) == [
            "https://example.org/cited/", "https://doi.org/10.1000/known", "https://example.org/opens",
            "https://example.org/titled",
        ])
        #expect(vetting.kept.map(\.confirmedBy) == [.citation, .crossref, .page, .page])
        // Crossref names a work it holds; the model's title gives way.
        #expect(vetting.kept[1].title == "Crossref's own title")
        #expect(vetting.kept[1].doi == "10.1000/known")
        #expect(vetting.kept[1].kind == .paper)
        // A page opened to check it names itself, so the sheet need not read it again for that.
        #expect(vetting.kept[2].title == "Opens")
        #expect(vetting.kept[3].title == "The page's own title")
        #expect(vetting.kept[0].site == "example.org")
        #expect(vetting.leftOut == 2)
        #expect(vetting.notSources == 0)
        // A cited page is never fetched again.
        #expect(await !log.openedPages.contains("https://example.org/cited/"))
    }

    @Test("Only an http(s) address is ever opened to check it")
    func openCheckTakesOnlyWebAddresses() async {
        #expect(await WebPageReader.opens("ftp://example.org/file.txt") == nil)
        #expect(await WebPageReader.opens("not a url") == nil)
        #expect(await WebPageReader.opens("/Users/someone/Papers/paper.pdf") == nil)
        #expect(WebPageReader.openCheckByteLimit == 65_536)
    }

    @Test("A page that answers from its site's front page is a soft 404, not a page that opens")
    func redirectToTheFrontPageDoesNotOpen() throws {
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }
        #expect(WebPageReader.redirectedToFrontPage(
            requested: try url("https://example.org/essays/missing"), answered: try url("https://example.org/")
        ))
        #expect(WebPageReader.redirectedToFrontPage(
            requested: try url("https://example.org/essays/missing"), answered: try url("https://www.example.org")
        ))
        // A page that moved to another page of its own still opens.
        #expect(!WebPageReader.redirectedToFrontPage(
            requested: try url("https://example.org/old"), answered: try url("https://example.org/new")
        ))
        // A front page asked for is a front page answered; the pick is set aside before this.
        #expect(!WebPageReader.redirectedToFrontPage(
            requested: try url("https://example.org/"), answered: try url("https://example.org/")
        ))
    }

    @Test("A page ForeverLM links rather than imports, or never takes, is not listed")
    func vettingSetsAsideWhatIsNeverASource() async throws {
        let googleDoc = "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit"
        let convoke = "https://platform.convoke.bio/mcp/results/123"
        try #require(StudioViewModel.linkedPageKind(forSourceURL: googleDoc) != nil)
        try #require(StudioViewModel.sourceRefusal(forSourceURL: convoke) != nil)
        let log = CallLog()
        let vetting = await WebSourceDiscovery.vet(
            [
                WebSourceDiscovery.Pick(url: googleDoc, title: "A Doc", why: "w", published: nil),
                WebSourceDiscovery.Pick(url: convoke, title: "A query result", why: "w", published: nil),
            ],
            citations: [AIWebCitation(url: googleDoc, title: "A Doc")],
            dependencies: Self.dependencies(log: log, openingPages: [googleDoc, convoke])
        )
        #expect(vetting.kept.isEmpty)
        #expect(vetting.notSources == 2)
        #expect(vetting.leftOut == 0)
        #expect(await log.openedPages.isEmpty)
    }

    @Test("A whole notebook or playlist, a YouTube page that is not a video, and home and search pages are set aside")
    func vettingSetsAsideWholesAndNonWorks() async throws {
        let playlist = "https://www.youtube.com/playlist?list=PLabcdefghijklmnop"
        let gemini = "https://notebook.google.com/notebook/\(UUID().uuidString.lowercased())"
        let channel = "https://www.youtube.com/@BlenderOfficial"
        let home = "https://www.example.org/"
        let bareHost = "https://example.org"
        let search = "https://www.biorxiv.org/search/nad%20decline"
        let scholar = "https://scholar.google.com/scholar?q=nad+decline"
        let video = "https://www.youtube.com/watch?v=abc123def45"
        try #require(YouTubePlaylistService.isPlaylistURL(playlist))
        try #require(GeminiNotebookService.isNotebookURL(gemini))
        try #require(YouTubeContainment.decision(for: channel) == .refused)
        let setAside = [playlist, gemini, channel, home, bareHost, search, scholar]
        for url in setAside {
            #expect(WebSourceDiscovery.setAsideReason(for: url) != nil, "\(url)")
        }
        #expect(WebSourceDiscovery.setAsideReason(for: video) == nil)
        #expect(WebSourceDiscovery.setAsideReason(for: "https://example.org/research/essay") == nil)

        let log = CallLog()
        let vetting = await WebSourceDiscovery.vet(
            (setAside + [video]).map { WebSourceDiscovery.Pick(url: $0, title: "t", why: "w", published: nil) },
            // Even a cited one: the engine citing a home page does not make it a work.
            citations: setAside.map { AIWebCitation(url: $0, title: "t") } + [AIWebCitation(url: video, title: "t")],
            dependencies: Self.dependencies(log: log)
        )
        #expect(vetting.kept.map(\.url) == [video])
        #expect(vetting.notSources == setAside.count)
        #expect(vetting.leftOut == 0)
        #expect(await log.openedPages.isEmpty)
    }

    // MARK: - Refusals

    @Test("A route with no web search it can bill (a Gemini pick) is refused before anything is sent")
    func unavailableWebSearchRefusesBeforeSending() async {
        let log = CallLog()
        await #expect(throws: WebSourceDiscoveryError.webSearchOff) {
            _ = try await WebSourceDiscovery.run(
                query: "",
                context: NotebookDiscoveryContext(title: "Ageing"),
                config: Self.config,
                dependencies: Self.dependencies(log: log, webAvailable: false)
            )
        }
        #expect(await log.searches == 0)
        // The real policy agrees: Gemini's search allowance is account-wide.
        let gemini = AITaskConfig(provider: .gemini, apiKey: "k", model: "gemini-3-pro")
        await MainActor.run {
            #expect(ReviewSessionManager.webSearchAccess(for: gemini) == .unavailable)
        }
    }

    @Test("The live search sends nothing through its transport on a route with no web search")
    func liveDependenciesSendNothingWhenRefused() async {
        DiscoverTransportStub.reset()
        let service = AIService(session: DiscoverTransportStub.session())
        let gemini = AITaskConfig(provider: .gemini, apiKey: "k", model: "gemini-3-pro")
        await #expect(throws: WebSourceDiscoveryError.self) {
            _ = try await WebSourceDiscovery.run(
                query: "NAD+ decline",
                context: NotebookDiscoveryContext(title: "Ageing"),
                config: gemini,
                dependencies: .live(aiService: service)
            )
        }
        #expect(DiscoverTransportStub.requestCount() == 0)
    }

    // MARK: - One run

    @Test("A run makes one search, checks every address, and names its ledger run")
    func runReturnsVettedCandidates() async throws {
        let log = CallLog()
        let reply = """
        {"summary": "Two ways in.", "sources": [
          {"url": "https://example.org/cited", "title": "Cited essay", "why": "Fits the notebook."},
          {"url": "https://example.org/invented", "title": "Invented", "why": "Sounds right."}
        ]}
        """
        let result = try await WebSourceDiscovery.run(
            query: "   ",
            context: NotebookDiscoveryContext(title: "Mitochondrial ageing"),
            count: 40,
            config: Self.config,
            dependencies: Self.dependencies(
                log: log,
                reply: reply,
                citations: [AIWebCitation(url: "https://example.org/cited", title: "Cited essay")]
            )
        )
        #expect(await log.searches == 1)
        // An empty query searches for the notebook's own subject.
        #expect(result.query == "Mitochondrial ageing")
        #expect(result.summary == "Two ways in.")
        #expect(result.candidates.map(\.title) == ["Cited essay"])
        #expect(result.candidates.first?.why == "Fits the notebook.")
        #expect(result.leftOut == 1)
        #expect(result.runID.hasPrefix("discover-"))
        #expect(await log.requests.first?.maxTokens == WebSourceDiscovery.maxTokens)
    }

    @Test("An empty or cut-off answer is asked once more with twice the room, and only once")
    func retriesOnceWithMoreRoom() async throws {
        let answer = #"{"summary": "One.", "sources": [{"url": "https://example.org/a", "title": "A"}]}"#
        let budget = WebSourceDiscovery.maxTokens
        let context = NotebookDiscoveryContext(title: "Ageing")

        let empty = SearchScript([.reply("  "), .reply(answer)])
        let afterEmpty = try await WebSourceDiscovery.run(
            query: "x", context: context, config: Self.config, dependencies: Self.scripted(empty)
        )
        #expect(afterEmpty.summary == "One.")
        #expect(await empty.budgets == [budget, budget * 2])

        let cutOff = SearchScript([.cutOff, .reply(answer)])
        let afterCutOff = try await WebSourceDiscovery.run(
            query: "x", context: context, config: Self.config, dependencies: Self.scripted(cutOff)
        )
        #expect(afterCutOff.summary == "One.")
        #expect(await cutOff.budgets == [budget, budget * 2])

        let firstTime = SearchScript([.reply(answer)])
        _ = try await WebSourceDiscovery.run(
            query: "x", context: context, config: Self.config, dependencies: Self.scripted(firstTime)
        )
        #expect(await firstTime.budgets == [budget])

        let neverAnswers = SearchScript([.reply(""), .reply(""), .reply(answer)])
        await #expect(throws: WebSourceDiscoveryError.unreadableReply) {
            _ = try await WebSourceDiscovery.run(
                query: "x", context: context, config: Self.config, dependencies: Self.scripted(neverAnswers)
            )
        }
        #expect(await neverAnswers.budgets == [budget, budget * 2])
    }

    @Test("The live search asks for room to reason, as every one-shot call does")
    func replyBudgetLeavesRoomForReasoning() {
        let routed = KeychainService.routedTextSelection(provider: Self.config.provider, model: Self.config.model)
        let budget = WebSourceDiscovery.replyTokenBudget(WebSourceDiscovery.maxTokens, config: Self.config)
        #expect(budget == AIService.effectiveReasoningAwareMaxTokens(
            WebSourceDiscovery.maxTokens, provider: routed.provider, model: routed.model
        ))
        #expect(budget > WebSourceDiscovery.maxTokens)
    }

    @Test("The user turn is only the search, the count and the date; the notebook rides the system prompt")
    func notebookStaysOutOfTheUserTurn() async throws {
        let many = (1...(WebSourceDiscovery.contextSourceLimit + 3)).map { "Source \($0)" }
        let context = NotebookDiscoveryContext(
            title: "Mitochondrial ageing",
            instructions: "Focus on human data.",
            researchQuestions: ["Does NAD+ fall with age?", " "],
            sources: many
        )
        let log = CallLog()
        _ = try await WebSourceDiscovery.run(
            query: "NAD+",
            context: context,
            count: 10,
            config: Self.config,
            dependencies: Self.dependencies(log: log),
            date: Date(timeIntervalSince1970: 0)
        )
        let request = try #require(await log.requests.first)
        #expect(request.user == "Search for: NAD+\nNumber of sources: up to 10\nToday: 1970-01-01")
        #expect(request.system == Prompts.sourceDiscovery)
        let notebook = request.notebook
        #expect(notebook.hasPrefix("\n\n"))
        #expect(notebook.contains("Notebook: Mitochondrial ageing"))
        #expect(notebook.contains("Instructions: Focus on human data."))
        #expect(notebook.contains("- Does NAD+ fall with age?"))
        #expect(notebook.contains("- Source 1\n"))
        #expect(!notebook.contains("- Source \(WebSourceDiscovery.contextSourceLimit + 1)\n"))
        #expect(notebook.contains("- and 3 more not listed here"))
        #expect(!request.user.contains("Notebook:"))
        #expect(
            WebSourceDiscovery.contextLine(title: "MitoSpace", author: "Smith", kind: "paper", year: "2026")
                == "MitoSpace — Smith (paper, 2026)"
        )

        // On the wire the search turn is the last user message, which is what
        // OpenRouter's web plugin searches with; the notebook is the message before it, not a second system block.
        let service = AIService()
        let payload = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: request.system, volatileSystem: request.notebook,
            turns: [.user(request.user)], tools: [], maxTokens: 200,
            model: "deepseek/deepseek-v3.2", effort: nil, webSearch: true, webSearchDepth: .discovery
        )
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.last?["role"] as? String == "user")
        // A model with prompt caching carries the turn as one text block with
        // a cache marker; either shape holds the search alone.
        let lastContent = messages.last?["content"]
        let lastText = lastContent as? String
            ?? (lastContent as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        #expect(lastText == request.user)
        let systemBlocks = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(systemBlocks.map { $0["text"] as? String } == [request.system])
        let notebookBlocks = try #require(messages[messages.count - 2]["content"] as? [[String: Any]])
        #expect(notebookBlocks.map { $0["text"] as? String } == [request.notebook])
    }

    @Test("Discover asks the web plugin for more results; every other body is as it was")
    @MainActor
    func discoveryDepthAsksForMoreResults() async throws {
        let service = AIService()
        let turns: [AIChatTurn] = [.user("Find sources")]
        let discovery = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: turns,
            tools: [], maxTokens: 200, model: "deepseek/deepseek-v3.2", effort: nil,
            webSearch: true, webSearchDepth: .discovery
        )
        let plugins = try #require(discovery["plugins"] as? [[String: Any]])
        #expect(plugins.first?["id"] as? String == "web")
        #expect(plugins.first?["max_results"] as? Int == AIWebSearchDepth.discovery.pluginMaxResults)
        for depth in [AIWebSearchDepth.standard, .deepResearch] {
            let plain = await service.makeOpenAIStyleToolPayload(
                provider: .openRouter, system: "S", volatileSystem: "", turns: turns,
                tools: [], maxTokens: 200, model: "deepseek/deepseek-v3.2", effort: nil,
                webSearch: true, webSearchDepth: depth
            )
            let plainPlugins = try #require(plain["plugins"] as? [[String: Any]])
            #expect(plainPlugins.first?.keys.sorted() == ["id"])
        }
        _ = try AIService.stableJSONBody(discovery)
    }
}

/// Counts every request a session made with it sends, and answers each with
/// an error: a refused run must leave the count at zero.
final class DiscoverTransportStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoverTransportStub.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock(); count = 0; lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

// MARK: - The sheet's session

@Suite("Notebook Discover")
@MainActor
struct NotebookDiscoverTests {

    private func makeViewModel() -> (StudioViewModel, StorageService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookDiscoverTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        return (StudioViewModel(storageService: storage), storage, root)
    }

    private func notebook(id: String, title: String, sourceIDs: [String], teamID: String? = nil) -> LearningGoalRecord {
        let now = Date()
        var record = LearningGoalRecord(
            id: id,
            title: title,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: sourceIDs.enumerated().map { index, sourceID in
                LearningGoalItem(id: "item-\(index)", goalID: id, sourceID: sourceID, addedAt: now)
            },
            kind: LearningGoalRecord.companionKind
        )
        record.teamID = teamID
        return record
    }

    private func services(
        log: WebSourceDiscoveryTests.CallLog,
        webAvailable: Bool = true,
        reply: String = #"{"summary": "", "sources": []}"#,
        citations: [AIWebCitation] = [],
        works: [LiteratureSearch.Work] = []
    ) -> SourceDiscoveryServices {
        SourceDiscoveryServices(
            resolveConfig: { WebSourceDiscoveryTests.config },
            web: WebSourceDiscoveryTests.dependencies(log: log, webAvailable: webAvailable, reply: reply, citations: citations),
            papers: { query, _ in LiteratureSearch.Result(query: query, hitCount: works.count, works: works) },
            runCost: { _ in 0.0123 }
        )
    }

    private func companionNotebook(_ storage: StorageService, vm: StudioViewModel) async throws -> LearningGoalRecord {
        let notebook = try await storage.createCompanionGoal(
            title: "Ageing", topic: "Ageing", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        await vm.loadLearningGoals()
        return notebook
    }

    @Test("A row is marked In notebook, In library or new, by address and by DOI")
    func marksWhatTheLibraryAndNotebookHold() {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let member = StudioArticle(url: "https://example.org/member", title: "Member", sourceType: .article, id: "member")
        var paper = StudioArticle(url: "https://www.cell.com/cell/fulltext/S0092-8674(26)01001-9", title: "MitoSpace", sourceType: .paper, id: "paper")
        paper.doi = "10.1016/j.cell.2026.08.028"
        vm.articles = [member, paper]
        let ageing = notebook(id: "nb", title: "Ageing", sourceIDs: ["member"])
        vm.learningGoals = [ageing]

        #expect(vm.discoveryHolding(forURL: "https://www.example.org/member/", in: ageing) == .inNotebook(sourceID: "member"))
        #expect(vm.discoveryHolding(forURL: "https://doi.org/10.1016/j.cell.2026.08.028", in: ageing) == .inLibrary(sourceID: "paper"))
        #expect(vm.discoveryHolding(forURL: "https://example.org/new", in: ageing) == .new)

        let context = vm.discoveryContext(for: ageing)
        #expect(context.title == "Ageing")
        #expect(context.sources == ["Member (article)"])
    }

    @Test("A team notebook holds the team's copy, and a row for the learner's own row at that address is In notebook")
    func teamNotebookMarksThroughTheTeamCopy() {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = StudioArticle(url: "https://example.org/shared-essay", title: "Shared essay", sourceType: .article, id: "own")
        let other = StudioArticle(url: "https://example.org/only-mine", title: "Only mine", sourceType: .article, id: "mine")
        // The team library names its copy by the learner's own row (`LibrarySourceList`).
        vm.articlesStore.teamCopyAliases = ["team-copy": "own"]
        vm.articles = [own, other]
        let teamNotebook = notebook(id: "team-nb", title: "Team notebook", sourceIDs: ["team-copy"], teamID: "team-1")
        vm.learningGoals = [teamNotebook]

        #expect(vm.discoveryHolding(forURL: "https://www.example.org/shared-essay/", in: teamNotebook) == .inNotebook(sourceID: "own"))
        #expect(vm.discoveryHolding(forURL: "https://example.org/only-mine", in: teamNotebook) == .inLibrary(sourceID: "mine"))
        #expect(vm.discoveryHolding(forURL: "https://example.org/elsewhere", in: teamNotebook) == .new)
        // A team this Mac does not know it may edit takes no imports.
        #expect(!vm.discoveryCanImport(into: teamNotebook))
    }

    @Test("The sheet opens on Web, and a route with no web search is refused there without sending anything")
    func refusesWebOnARouteWithoutSearch() async {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.learningGoals = [notebook(id: "nb", title: "Ageing", sourceIDs: [])]
        let log = WebSourceDiscoveryTests.CallLog()
        let session = NotebookDiscoverySession(notebookID: "nb", services: services(log: log, webAvailable: false))
        #expect(session.mode == .web)
        #expect(session.listing.phase == .idle)

        await session.runWebSearch("NAD+", context: NotebookDiscoveryContext(title: "Ageing"), vm: vm)
        guard case .refused(let message) = session.listing.phase else {
            Issue.record("Expected a refusal, got \(session.listing.phase)")
            return
        }
        #expect(message.contains("Papers"))
        #expect(await log.searches == 0)
    }

    @Test("Web rows the notebook lacks start ticked; a row it holds has no box; the cost is read from the ledger")
    func webRowsStartTicked() async {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.articles = [StudioArticle(url: "https://example.org/held", title: "Held", sourceType: .article, id: "held")]
        vm.learningGoals = [notebook(id: "nb", title: "Ageing", sourceIDs: ["held"])]
        let log = WebSourceDiscoveryTests.CallLog()
        let reply = """
        {"summary": "What is missing.", "sources": [
          {"url": "https://example.org/new", "title": "New", "why": "Fits."},
          {"url": "https://example.org/held", "title": "Held", "why": "Fits too."}
        ]}
        """
        let session = NotebookDiscoverySession(
            notebookID: "nb",
            services: services(
                log: log,
                reply: reply,
                citations: [
                    AIWebCitation(url: "https://example.org/new", title: "New"),
                    AIWebCitation(url: "https://example.org/held", title: "Held"),
                ]
            ),
            mode: .web
        )
        await session.runWebSearch("", context: vm.discoveryContext(for: vm.notebook(id: "nb")!), vm: vm)
        #expect(session.listing.phase == .results)
        #expect(session.listing.summary == "What is missing.")
        #expect(session.listing.rows.map(\.holding) == [.new, .inNotebook(sourceID: "held")])
        // A web row says how its address was confirmed, so the sheet knows whose title to show.
        #expect(session.listing.rows.map(\.confirmedBy) == [.citation, .citation])
        #expect(session.selectedRows.map(\.url) == ["https://example.org/new"])
        #expect(session.allTickableSelected)
        #expect(session.listing.costUSD == 0.0123)

        session.toggleSelectAll()
        #expect(session.selectedCount == 0)
        session.setSelected(true, rowID: session.listing.rows[0].id)
        #expect(session.selectedCount == 1)
        // A row the notebook holds cannot be ticked.
        session.setSelected(true, rowID: session.listing.rows[1].id)
        #expect(session.selectedCount == 1)
    }

    @Test("PubMed rows start unticked and say what the library holds")
    func papersRowsStartUnticked() async {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var held = StudioArticle(url: "https://www.nature.com/articles/s41586-020-0001-1", title: "Held paper", sourceType: .paper, id: "held")
        held.doi = "10.1038/s41586-020-0001-1"
        vm.articles = [held]
        vm.learningGoals = [notebook(id: "nb", title: "Ageing", sourceIDs: [])]
        let works = [
            LiteratureSearch.Work(
                title: "Held paper", authors: "Smith J", journal: "Nature", year: 2020,
                doi: "10.1038/s41586-020-0001-1", pmid: "1", pmcid: "PMC1", isPreprint: false, isReview: true,
                abstract: "An abstract."
            ),
            LiteratureSearch.Work(
                title: "New paper", authors: nil, journal: nil, year: nil,
                doi: nil, pmid: "2", pmcid: nil, isPreprint: true, isReview: false, abstract: nil
            ),
        ]
        let log = WebSourceDiscoveryTests.CallLog()
        let session = NotebookDiscoverySession(notebookID: "nb", services: services(log: log, works: works), mode: .papers)
        await session.runPapersSearch("", context: NotebookDiscoveryContext(title: "Ageing"), vm: vm)
        #expect(session.listing.query == "Ageing")
        #expect(session.listing.rows.map(\.holding) == [.inLibrary(sourceID: "held"), .new])
        #expect(session.listing.rows[0].byline == "Smith J · Nature · 2020")
        #expect(session.listing.rows[0].isFreeFullText && session.listing.rows[0].isReview)
        #expect(session.listing.rows[1].url == "https://pubmed.ncbi.nlm.nih.gov/2/")
        #expect(session.listing.rows.allSatisfy { $0.kind == .paper })
        #expect(session.listing.rows.allSatisfy { $0.confirmedBy == nil })
        #expect(session.selectedCount == 0)
        #expect(await log.searches == 0)
    }

    @Test("Importing files a held source into the notebook once, and refuses a read-only or missing notebook")
    func importFilesHeldSourcesThroughTheSeam() async throws {
        let (vm, storage, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = StudioArticle(url: "https://example.org/held", title: "Held", sourceType: .article, id: "held")
        source.state = .ready
        source.content = "Readable text this library holds."
        try await storage.saveSource(source)
        vm.articles = [source]
        let notebook = try await companionNotebook(storage, vm: vm)

        #expect(await vm.importDiscovered("https://www.example.org/held/", intoNotebook: notebook.id) == .filed(sourceID: "held"))
        #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs == ["held"])
        #expect(await vm.importDiscovered("https://example.org/held", intoNotebook: notebook.id) == .alreadyInNotebook(sourceID: "held"))
        let missing = await vm.importDiscovered("https://example.org/held", intoNotebook: "no-such-notebook")
        #expect(!missing.landed)
        // Each row says nothing; the import's own summary is the one toast.
        #expect(vm.toastMessage == nil)
    }

    @Test("A new address is added to the library and the notebook without a toast of its own")
    func importAddsANewAddress() async throws {
        let (vm, storage, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = try await companionNotebook(storage, vm: vm)

        let outcome = await vm.importDiscovered("https://example.org/new-essay", intoNotebook: notebook.id)
        guard case .added(let sourceID) = outcome else {
            Issue.record("Expected .added, got \(outcome)")
            return
        }
        #expect(vm.articlesById[sourceID]?.url == "https://example.org/new-essay")
        #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs == [sourceID])
        #expect(vm.toastMessage == nil)
    }

    @Test("A Google Doc, a Convoke result or a playlist is refused before anything is written")
    func importRefusesWhatDiscoverNeverLists() async throws {
        let (vm, storage, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = try await companionNotebook(storage, vm: vm)

        let googleDoc = await vm.importDiscovered("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit", intoNotebook: notebook.id)
        guard case .failed(let docReason) = googleDoc else {
            Issue.record("Expected a refusal, got \(googleDoc)")
            return
        }
        #expect(docReason.contains(LinkedGoogleDoc.label))
        let convoke = await vm.importDiscovered("https://platform.convoke.bio/mcp/results/123", intoNotebook: notebook.id)
        #expect(convoke == .failed(try #require(StudioViewModel.sourceRefusal(forSourceURL: "https://platform.convoke.bio/mcp/results/123"))))
        let playlist = await vm.importDiscovered("https://www.youtube.com/playlist?list=PLabcdefghijklmnop", intoNotebook: notebook.id)
        #expect(!playlist.landed)

        // Nothing was linked, imported or filed.
        #expect(vm.artifacts.isEmpty)
        #expect(vm.articles.isEmpty)
        #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs.isEmpty == true)
    }

    @Test("Putting the Sources column's results card away empties its list")
    func dismissEmptiesTheList() async {
        let (vm, _, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let works = [
            LiteratureSearch.Work(
                title: "A paper", authors: nil, journal: nil, year: nil,
                doi: nil, pmid: "1", pmcid: nil, isPreprint: false, isReview: false, abstract: nil
            ),
        ]
        let log = WebSourceDiscoveryTests.CallLog()
        let session = NotebookDiscoverySession(notebookID: "nb", services: services(log: log, works: works), mode: .papers)
        await session.runPapersSearch("", context: NotebookDiscoveryContext(title: "Ageing"), vm: vm)
        #expect(session.listing.phase == .results)
        #expect(session.listing.rows.count == 1)
        session.dismissListing()
        #expect(session.listing.phase == .idle)
        #expect(session.listing.rows.isEmpty)
        #expect(session.listing.query == nil)
    }

    @Test("One toast sums an import up")
    func importSummaryReadsPlainly() {
        let title = "Ageing"
        #expect(NotebookDiscoverySession.importSummary([.added(sourceID: "a"), .filed(sourceID: "b")], notebookTitle: title)
            == "Added 2 sources to \u{201C}Ageing\u{201D}")
        #expect(NotebookDiscoverySession.importSummary([.added(sourceID: "a"), .alreadyInNotebook(sourceID: "b"), .failed("x")], notebookTitle: title)
            == "Added 1 source to \u{201C}Ageing\u{201D}; 1 already there; 1 could not be added")
        #expect(NotebookDiscoverySession.importSummary([.failed("PubMed did not answer.")], notebookTitle: title)
            == "PubMed did not answer.")
        #expect(NotebookDiscoverySession.importSummary([.alreadyInNotebook(sourceID: "a")], notebookTitle: title)
            == "It was already in \u{201C}Ageing\u{201D}")
    }
}

// MARK: - discover_sources

@Suite("discover_sources")
struct DiscoverSourcesToolTests {

    private func services(
        log: WebSourceDiscoveryTests.CallLog,
        webAvailable: Bool = true,
        reply: String = #"{"summary": "", "sources": []}"#,
        citations: [AIWebCitation] = []
    ) -> SourceDiscoveryServices {
        SourceDiscoveryServices(
            resolveConfig: { WebSourceDiscoveryTests.config },
            web: WebSourceDiscoveryTests.dependencies(
                log: log, webAvailable: webAvailable, reply: reply, citations: citations
            ),
            papers: { query, _ in LiteratureSearch.Result(query: query, hitCount: 0, works: []) },
            runCost: { _ in nil }
        )
    }

    @Test("discover_sources is a registered, paid, self-gated, web-only tool that chat leaves to outside assistants")
    @MainActor
    func registration() {
        let tools = MCPToolRegistry.shared.tools
        let tool = tools.first { $0.name == "discover_sources" }
        #expect(tool != nil)
        let properties = tool?.inputSchema["properties"] as? [String: Any]
        #expect(properties?["approved_spend_usd"] != nil)
        #expect(properties?["notebook_id"] != nil)
        // Web only: papers are search_literature's, free.
        #expect(properties?["mode"] == nil)
        #expect(tool?.description.contains("search_literature") == true)
        #expect((tool?.inputSchema["required"] as? [String]) == ["notebook_id"])
        #expect(MCPToolRegistry.paidWorkToolNames.contains("discover_sources"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("discover_sources"))
        #expect(MCPToolActivityTitle.shownToolNames.contains("discover_sources"))
        #expect(MCPToolActivityTitle.forTool("discover_sources", arguments: [:]) != nil)
        let annotations = MCPToolRegistry.annotations(for: "discover_sources")
        #expect(annotations["readOnlyHint"] as? Bool == false)
        #expect(annotations["openWorldHint"] as? Bool == true)
        #expect(ReviewSessionManager.chatExcludedToolNames.contains("discover_sources"))
        // The description never claims notebook_id on the import tools.
        #expect(tool?.description.contains("add_notebook_sources") == true)
    }

    @Test("An unknown or archived Notebook, a bad count or unknown sources, are refused before anything is searched")
    func refusesBadInputBeforeSearching() async throws {
        let (store, path) = try TestStores.mcp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = WebSourceDiscoveryTests.CallLog()
        let services = services(log: log)

        await #expect(throws: MCPError.self) {
            _ = try await store.discoverSources(
                notebookID: "no-such-notebook", query: "x", count: nil, sourceIDs: nil, services: services
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.discoverSources(
                notebookID: "no-such-notebook", query: "x", count: 40, sourceIDs: nil, services: services
            )
        }
        let ks = try store.knowledgeStore()
        let notebook = try ks.createCompanionGoal(
            title: "Ageing", topic: "Ageing", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        await #expect(throws: MCPError.self) {
            _ = try await store.discoverSources(
                notebookID: notebook.id, query: "x", count: nil, sourceIDs: ["missing-source"], services: services
            )
        }
        #expect(await log.searches == 0)
    }

    @Test("A model with no web search is refused before anything is spent, pointing at search_literature")
    func refusesWebSearchItCannotPayFor() async throws {
        let (store, path) = try TestStores.mcp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try store.knowledgeStore().createCompanionGoal(
            title: "Ageing", topic: "Ageing", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let log = WebSourceDiscoveryTests.CallLog()
        do {
            _ = try await store.discoverSources(
                notebookID: notebook.id, query: nil, count: nil, sourceIDs: nil,
                services: services(log: log, webAvailable: false)
            )
            Issue.record("A model with no web search should be refused")
        } catch {
            #expect(error is MCPError)
            #expect(error.localizedDescription.contains("search_literature"))
        }
        #expect(await log.searches == 0)
    }

    @Test("Candidates say what the library and the Notebook already hold, and what was set aside")
    func marksCandidates() async throws {
        let (store, path) = try TestStores.mcp()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ks = try store.knowledgeStore()
        let url = "https://example.org/held"
        var article = StudioArticle(url: url, title: "Held", sourceType: .article, discoveryOrigin: .manual, id: "held")
        article.domain = "example.org"
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = "Readable text this library holds for the test."
        article.wordCount = 8
        article.state = .ready
        try ks.saveSource(article)
        let notebook = try ks.createCompanionGoal(
            title: "Ageing", topic: "Ageing", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["held"]
        )
        let reply = """
        {"summary": "Two pages.", "sources": [
          {"url": "https://example.org/held", "title": "Held", "why": "Already read."},
          {"url": "https://example.org/new", "title": "New", "why": "Not yet read."},
          {"url": "https://example.org/invented", "title": "Invented", "why": "Never there."},
          {"url": "https://example.org/", "title": "The site", "why": "A home page."}
        ]}
        """
        let log = WebSourceDiscoveryTests.CallLog()
        let text = try await store.discoverSources(
            notebookID: notebook.id, query: "ageing", count: nil, sourceIDs: nil,
            services: services(
                log: log,
                reply: reply,
                citations: [
                    AIWebCitation(url: "https://example.org/held", title: "Held"),
                    AIWebCitation(url: "https://example.org/new", title: "New"),
                ]
            )
        )
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(payload["summary"] as? String == "Two pages.")
        #expect(payload["left_out"] as? Int == 1)
        #expect(payload["not_sources"] as? Int == 1)
        #expect(payload["mode"] == nil)
        let candidates = try #require(payload["candidates"] as? [[String: Any]])
        #expect(candidates.map { $0["url"] as? String } == ["https://example.org/held", "https://example.org/new"])
        #expect(candidates[0]["in_library"] as? Bool == true)
        #expect(candidates[0]["library_source_id"] as? String == "held")
        #expect(candidates[0]["in_notebook"] as? Bool == true)
        #expect(candidates[1]["in_library"] as? Bool == false)
        #expect(candidates[1]["in_notebook"] as? Bool == false)
        #expect(candidates[1]["kind"] as? String == "article")
        #expect((payload["guidance"] as? String)?.contains("import_paper_from_url") == true)
        #expect(await log.searches == 1)
    }
}
