import Foundation

// Discover, in a notebook's Add sources (product owner, 2026-09-30, pointing at
// Gemini Notebook's Source Discovery: "they also have this for source
// discovery"). One web search with the notebook as context returns a short
// list of works to tick and import, each with one line on why it fits.
//
// The split is the one every candidate list in ForeverLM keeps: the model
// judges relevance and writes the why; ForeverLM owns identity. An address is
// listed only when something real stands behind it — the search engine cited
// it, Crossref knows the DOI it carries, or the page opens — and its kind is
// read off the URL by `StudioViewModel.detectSourceType`, never taken from the
// model. Nothing here writes to the library: importing what the learner ticks
// goes through the ordinary import routes.
//
// Named apart from `SourceDiscovery`, which parses reading lists and podcast
// feeds.

/// What a notebook is about, as Discover's search reads it.
struct NotebookDiscoveryContext: Equatable, Sendable {
    var title: String
    /// The notebook's standing Instructions (`LearningGoalRecord.description`).
    var instructions: String?
    var researchQuestions: [String]
    /// The sources the search works from, one line each ("Title — Author
    /// (paper, 2021)"): titles only, never their text.
    var sources: [String]

    init(title: String, instructions: String? = nil, researchQuestions: [String] = [], sources: [String] = []) {
        self.title = title
        self.instructions = instructions
        self.researchQuestions = researchQuestions
        self.sources = sources
    }
}

/// One work a search proposed, after ForeverLM checked its address.
struct WebSourceCandidate: Identifiable, Equatable, Sendable {
    /// How the address was confirmed to stand for something real.
    enum Confirmation: String, Equatable, Sendable {
        /// The search engine cited this page in its answer.
        case citation
        /// Crossref holds the DOI the address carries.
        case crossref
        /// A request for the page answered.
        case page
    }

    var id: String { identity }
    /// `URLNormalizer.normalize(url)`: one row per page.
    let identity: String
    let url: String
    /// The work's name, from the most deterministic source there is: Crossref's
    /// record for a confirmed DOI, else the page's own title from the open
    /// check, else the model's.
    var title: String
    let why: String
    let published: String?
    /// Read off the URL (`StudioViewModel.detectSourceType`); a model never chooses it.
    let kind: VideoCitedPaper.Kind
    /// The DOI the address carries (`PaperService.extractDOI`).
    let doi: String?
    /// The host without `www.`, for the row's "Kind · site" line.
    let site: String
    let confirmedBy: Confirmation
}

struct WebSourceDiscoveryResult: Equatable, Sendable {
    let query: String
    let summary: String
    let candidates: [WebSourceCandidate]
    /// Listed by the model, but neither cited, known to Crossref, nor
    /// answering: left out rather than shown as something to import.
    let leftOut: Int
    /// Listed, but an address no source is made from
    /// (`WebSourceDiscovery.setAsideReason(for:)`): a page ForeverLM links
    /// rather than imports, one it refuses outright, a whole notebook or
    /// playlist, a YouTube page that is not a video, a home or search page.
    let notSources: Int
    /// The usage-ledger session the search's calls were recorded under, for
    /// reading what the run cost.
    let runID: String
}

enum WebSourceDiscoveryError: LocalizedError, Equatable {
    /// Web search cannot ride this route: a model whose search ForeverLM
    /// cannot bill per request.
    case webSearchOff
    /// The model's answer was not the JSON object the prompt asks for.
    case unreadableReply

    var errorDescription: String? {
        switch self {
        case .webSearchOff:
            return "Web search is off for the chat's model. Choose another Chat model, or search Papers, which is free."
        case .unreadableReply:
            return "The search came back in a form ForeverLM could not read. Try again."
        }
    }
}

enum WebSourceDiscovery {
    /// How many works a search lists: 10 unless asked, at least 5 and at most 15.
    static let defaultCount = 10
    static let countRange = 5...15
    /// The visible answer's budget: a summary and up to fifteen works with a
    /// line each. The request asks for more (`replyTokenBudget`), because a
    /// reasoning model spends its thinking against the same ceiling.
    static let maxTokens = 4_000
    /// Notebook sources named in the request. A notebook can hold hundreds;
    /// past this the line says how many more there are rather than listing
    /// them, so the request stays a search and not a library dump. Any of
    /// them the search proposes anyway is marked In notebook.
    static let contextSourceLimit = 80
    /// Address checks running at once.
    static let vettingConcurrency = 6

    /// One work as the model listed it.
    struct Pick: Equatable, Sendable {
        let url: String
        let title: String
        let why: String
        let published: String?
    }

    /// The one search, as it is sent.
    struct SearchRequest: Equatable, Sendable {
        /// The task's prompt: the stable head of the system prompt.
        let system: String
        /// The notebook — title, Instructions, research questions, the
        /// sources it holds — as the system prompt's volatile tail. It stays
        /// out of the user turn because OpenRouter's web plugin builds its
        /// search query from the last user message.
        let notebook: String
        /// The one user turn: what to search for, how many, and the date.
        let user: String
        /// The visible answer's budget; the live search widens it for
        /// reasoning (`replyTokenBudget`).
        let maxTokens: Int

        func withMaxTokens(_ maxTokens: Int) -> SearchRequest {
            SearchRequest(system: system, notebook: notebook, user: user, maxTokens: maxTokens)
        }
    }

    /// What the one search returned: the model's text and the engine's own
    /// citations.
    struct SearchReply: Sendable {
        let text: String
        let citations: [AIWebCitation]
    }

    /// Everything a run needs from outside, so tests can stand in for the
    /// network and the model.
    struct Dependencies: Sendable {
        /// Whether the route this config travels can carry web search
        /// (`ReviewSessionManager.webSearchAccess(for:)` is not `.unavailable`).
        var webSearchIsAvailable: @Sendable (AITaskConfig) async -> Bool
        var search: @Sendable (_ config: AITaskConfig, _ request: SearchRequest) async throws -> SearchReply
        /// Crossref's title for a DOI it holds; nil when it holds none.
        var crossrefTitle: @Sendable (String) async -> String?
        /// What a bounded request for the address found; nil when it does
        /// not open (`WebPageReader.opens`).
        var pageOpens: @Sendable (String) async -> WebPageReader.Opening?

        /// The real network and model.
        static func live(aiService: AIService) -> Dependencies {
            Dependencies(
                webSearchIsAvailable: { config in
                    await MainActor.run { ReviewSessionManager.webSearchAccess(for: config) != .unavailable }
                },
                search: { config, request in
                    let result = try await aiService.streamChatWithTools(
                        config: config,
                        system: request.system,
                        volatileSystem: request.notebook,
                        turns: [.user(request.user)],
                        tools: [],
                        maxTokens: WebSourceDiscovery.replyTokenBudget(request.maxTokens, config: config),
                        webSearch: true,
                        webSearchDepth: .discovery,
                        onTextDelta: { _ in }
                    )
                    return SearchReply(text: result.text, citations: result.webCitations)
                },
                crossrefTitle: { doi in await SlideCitationService.crossrefRecord(doi: doi)?.title },
                pageOpens: { url in await WebPageReader.opens(url) }
            )
        }
    }

    /// The output ceiling a search asks for: the visible answer's budget,
    /// widened for a model that reasons before it answers, as every one-shot
    /// and chat call widens it (`AIService.effectiveReasoningAwareMaxTokens`),
    /// read for the host the request actually travels to.
    static func replyTokenBudget(_ visibleTokens: Int, config: AITaskConfig) -> Int {
        let routed = KeychainService.routedTextSelection(provider: config.provider, model: config.model, speed: config.speed)
        return AIService.effectiveReasoningAwareMaxTokens(visibleTokens, provider: routed.provider, model: routed.model)
    }

    /// The refusal a run meets before it calls anything, or nil when the
    /// route can search the web.
    static func webSearchRefusal(
        config: AITaskConfig,
        dependencies: Dependencies
    ) async -> WebSourceDiscoveryError? {
        if await !dependencies.webSearchIsAvailable(config) { return .webSearchOff }
        return nil
    }

    /// Search the web for what the notebook is missing. Refuses before any
    /// request when the route cannot search; otherwise makes one call (two
    /// when the first answer comes back empty or cut off) and checks every
    /// address it lists.
    static func run(
        query rawQuery: String,
        context: NotebookDiscoveryContext,
        count requestedCount: Int = defaultCount,
        config: AITaskConfig,
        dependencies: Dependencies,
        date: Date = Date()
    ) async throws -> WebSourceDiscoveryResult {
        if let refusal = await webSearchRefusal(config: config, dependencies: dependencies) {
            throw refusal
        }
        let count = min(max(requestedCount, countRange.lowerBound), countRange.upperBound)
        let query = searchQuery(rawQuery, context: context)
        let request = SearchRequest(
            system: AITask.sourceDiscovery.effectivePrompt ?? Prompts.sourceDiscovery,
            notebook: notebookContext(context),
            user: userMessage(query: query, count: count, date: date),
            maxTokens: maxTokens
        )
        let runID = "discover-\(UUID().uuidString.lowercased())"

        // The chat route has no backups to walk (`AIBackupModels.slot(for:)`
        // names only Background slots), so this is the one model's answer.
        let reply = try await AIUsageAttribution.$sessionID.withValue(runID) {
            try await AIUsageAttribution.$activityID.withValue(runID) {
                try await searchWithRoom(request, config: config, dependencies: dependencies)
            }
        }
        let decoded = try decodeReply(reply.text, limit: count)
        let vetted = await vet(decoded.picks, citations: reply.citations, dependencies: dependencies)
        return WebSourceDiscoveryResult(
            query: query,
            summary: decoded.summary,
            candidates: vetted.kept,
            leftOut: vetted.leftOut,
            notSources: vetted.notSources,
            runID: runID
        )
    }

    /// The search, asked once more with twice the room when its answer comes
    /// back empty or cut off: a reasoning model that spent the budget
    /// thinking, as chat retries it. The second ask is a second paid search,
    /// so there is only one.
    static func searchWithRoom(
        _ request: SearchRequest,
        config: AITaskConfig,
        dependencies: Dependencies
    ) async throws -> SearchReply {
        do {
            let reply = try await dependencies.search(config, request)
            if !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reply }
        } catch AIError.outputTokenLimit {
            // Cut off before the list closed; asked again below.
        }
        try Task.checkCancellation()
        return try await dependencies.search(config, request.withMaxTokens(request.maxTokens * 2))
    }

    /// What the search is for: the learner's words, or with none the
    /// notebook's own subject.
    static func searchQuery(_ raw: String, context: NotebookDiscoveryContext) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? context.title.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    // MARK: - The request

    /// The notebook as the system prompt's tail: its title, Instructions,
    /// research questions, and the sources it already holds, titles only.
    static func notebookContext(_ context: NotebookDiscoveryContext) -> String {
        var lines = ["", "", "Notebook: \(context.title)"]
        if let instructions = context.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            lines.append("Instructions: \(instructions)")
        }
        let questions = context.researchQuestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !questions.isEmpty {
            lines.append("Research questions:")
            lines += questions.map { "- \($0)" }
        }
        if context.sources.isEmpty {
            lines.append("The notebook holds no sources yet.")
        } else {
            lines.append("Already in the notebook (\(context.sources.count)):")
            lines += context.sources.prefix(contextSourceLimit).map { "- \($0)" }
            let unlisted = context.sources.count - contextSourceLimit
            if unlisted > 0 {
                lines.append("- and \(unlisted) more not listed here")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The one user turn, and so the words the web plugin searches with: the
    /// query first, then how many and the date.
    static func userMessage(query: String, count: Int, date: Date) -> String {
        [
            "Search for: \(query)",
            "Number of sources: up to \(count)",
            "Today: \(String(ISO8601DateFormatter().string(from: date).prefix(10)))",
        ].joined(separator: "\n")
    }

    /// One notebook source as the request names it: "Title — Author (paper, 2021)".
    static func contextLine(title: String, author: String?, kind: String?, year: String?) -> String {
        var line = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            line += " — \(author)"
        }
        let detail = [kind, year]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !detail.isEmpty { line += " (\(detail.joined(separator: ", ")))" }
        return line
    }

    // MARK: - Reading the answer

    /// The summary and the works the model listed: http(s) addresses only, one
    /// per page (by address, then by DOI), at most `limit`. Code fences around
    /// the object are tolerated; anything that is not the object throws.
    static func decodeReply(_ reply: String, limit: Int) throws -> (summary: String, picks: [Pick]) {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = object["sources"] as? [Any] else {
            throw WebSourceDiscoveryError.unreadableReply
        }
        let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var picks: [Pick] = []
        var seenAddresses = Set<String>()
        var seenDOIs = Set<String>()
        for case let entry as [String: Any] in sources {
            guard picks.count < limit else { break }
            guard let url = (entry["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = URL(string: url), parsed.host?.isEmpty == false,
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard seenAddresses.insert(URLNormalizer.normalize(url)).inserted else { continue }
            if let doi = PaperService.extractDOI(from: url) {
                guard seenDOIs.insert(StudioViewModel.normalizeDOI(doi)).inserted else { continue }
            }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let why = (entry["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let published = Self.publishedText(entry["published"])
            picks.append(Pick(url: url, title: title, why: why, published: published))
        }
        return (summary, picks)
    }

    /// "2021" or "2021-03-04", whether the model wrote it as text or a number.
    private static func publishedText(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        default: text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Checking the addresses

    /// Why an address is never offered as a source to import, or nil when it
    /// may be one. These are the import routes' own rules, asked before
    /// anything is fetched, so a pick never reaches an import that would
    /// make something else of it: a page ForeverLM links rather than imports
    /// (`linkedPageKind`), one it refuses (`sourceRefusal`), a Gemini
    /// notebook or YouTube playlist (each imports as a whole Notebook or
    /// course), a page of YouTube's own that is not a video
    /// (`YouTubeContainment`); and the pages the prompt rules out because
    /// they are not a work: a site's home page and a search page.
    static func setAsideReason(for url: String) -> String? {
        if let kind = StudioViewModel.linkedPageKind(forSourceURL: url) {
            return "That is a \(kind.label): ForeverLM links it in \(kind.section.title) rather than adding it as a source."
        }
        if let refusal = StudioViewModel.sourceRefusal(forSourceURL: url) { return refusal }
        if GeminiNotebookService.isNotebookURL(url) {
            return "That is a whole Gemini notebook, which comes in as a notebook of its own, not one source."
        }
        if YouTubePlaylistService.isPlaylistURL(url) {
            return "That is a YouTube playlist, which comes in as a course, not one source."
        }
        if YouTubeContainment.decision(for: url) == .refused { return YouTubeContainment.refusalMessage }
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if isHomePath(parsed.path) { return "That is a site's home page, not a work to read." }
        if looksLikeSearch(parsed) { return "That is a search page, not a work to read." }
        return nil
    }

    /// A path that names no page of its own: a site's front page.
    static func isHomePath(_ path: String) -> Bool {
        path.isEmpty || path == "/"
    }

    /// A results page rather than a work: a `search` path segment, or a `q`
    /// query.
    private static func looksLikeSearch(_ url: URL) -> Bool {
        if url.path.lowercased().split(separator: "/").contains("search") { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name.lowercased() == "q" }
    }

    struct Vetting: Equatable, Sendable {
        var kept: [WebSourceCandidate]
        var leftOut: Int
        var notSources: Int
    }

    /// Keeps a pick when the engine cited its page, Crossref holds the DOI it
    /// carries, or the page answers, in that order of cost; the model's order
    /// is kept. A pick no source is made from (`setAsideReason`) is dropped
    /// before any check and counted apart.
    static func vet(
        _ picks: [Pick],
        citations: [AIWebCitation],
        dependencies: Dependencies
    ) async -> Vetting {
        let cited = Set(citations.map(\.pageIdentity))
        var verdicts = [Verdict?](repeating: nil, count: picks.count)
        var setAside = Set<Int>()
        var toCheck: [Int] = []
        for (index, pick) in picks.enumerated() {
            if setAsideReason(for: pick.url) != nil {
                setAside.insert(index)
                continue
            }
            if cited.contains(AIWebCitation(url: pick.url, title: pick.title).pageIdentity) {
                verdicts[index] = Verdict(confirmation: .citation, title: nil)
            } else {
                toCheck.append(index)
            }
        }

        var offset = 0
        while offset < toCheck.count {
            let batch = toCheck[offset..<min(offset + vettingConcurrency, toCheck.count)]
            await withTaskGroup(of: (Int, Verdict?).self) { group in
                for index in batch {
                    let url = picks[index].url
                    group.addTask {
                        // Bound before the tuple is built (AGENTS.md: a tuple
                        // around an await in a task closure miscompiles at -O).
                        let verdict = await Self.check(url, dependencies: dependencies)
                        return (index, verdict)
                    }
                }
                for await (index, verdict) in group {
                    verdicts[index] = verdict
                }
            }
            offset += vettingConcurrency
        }

        var kept: [WebSourceCandidate] = []
        var leftOut = 0
        for (index, pick) in picks.enumerated() where !setAside.contains(index) {
            guard let verdict = verdicts[index] else {
                leftOut += 1
                continue
            }
            kept.append(candidate(for: pick, verdict: verdict))
        }
        return Vetting(kept: kept, leftOut: leftOut, notSources: setAside.count)
    }

    private struct Verdict: Sendable {
        let confirmation: WebSourceCandidate.Confirmation
        /// Crossref's title, or the page's own from the open check; either
        /// replaces the model's.
        let title: String?
    }

    private static func check(_ url: String, dependencies: Dependencies) async -> Verdict? {
        if let doi = PaperService.extractDOI(from: url),
           let title = await dependencies.crossrefTitle(doi) {
            return Verdict(confirmation: .crossref, title: nonEmpty(title))
        }
        if let opening = await dependencies.pageOpens(url) {
            // The head was read for the check, so its title names the row
            // without the sheet reading the page again for it.
            return Verdict(confirmation: .page, title: opening.title.flatMap(nonEmpty))
        }
        return nil
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func candidate(for pick: Pick, verdict: Verdict) -> WebSourceCandidate {
        let host = URL(string: pick.url)?.host?.lowercased() ?? ""
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let title = verdict.title ?? (pick.title.isEmpty ? site : pick.title)
        return WebSourceCandidate(
            identity: URLNormalizer.normalize(pick.url),
            url: pick.url,
            title: title,
            why: pick.why,
            published: pick.published,
            kind: kind(of: pick.url),
            doi: PaperService.extractDOI(from: pick.url),
            site: site,
            confirmedBy: verdict.confirmation
        )
    }

    /// The kind an address imports as, read off the URL the way every import
    /// route reads it.
    static func kind(of url: String) -> VideoCitedPaper.Kind {
        VideoCitedPaper.Kind(sourceType: StudioViewModel.detectSourceType(url: url))
    }
}
