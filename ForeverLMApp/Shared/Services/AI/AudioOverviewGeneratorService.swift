import Foundation

// MARK: - The carrier, on the Mac

/// What needs `StudioArticle` and `SourceIdentity`: the id and the record of
/// the hidden source an overview's script and audio live on
/// (`foreverlm://audio-overview/<artifactID>`). The grammar is
/// `AudioOverviewScript`'s; this mirrors `GeneratedExplainer` over
/// `ExplainerScript`.
enum GeneratedAudioOverview {
    /// The carrier's source id, from the id of the Artifact it belongs to: the
    /// same normalizer and hash every source id comes from, so the phone,
    /// which hashes the same URL, finds the same row.
    static func carrierSourceID(artifactID: String) -> String {
        SourceIdentity.stableID(for: AudioOverviewScript.url(artifactID: artifactID))
    }

    /// Whether a source is an audio overview's carrier.
    static func isCarrier(_ article: StudioArticle) -> Bool {
        AudioOverviewScript.isCarrierURL(article.url)
    }

    /// The Artifact a carrier belongs to, or nil for any other source.
    static func artifactID(ofCarrier article: StudioArticle) -> String? {
        AudioOverviewScript.artifactID(fromCarrierURL: article.url)
    }

    /// Whether a record is an audio overview, read without its body: its
    /// kind says so, or — for a record an older build saved back without
    /// the kind — the library holds the carrier its id names. A list cannot
    /// read every Doc's body to find the marker
    /// (`AudioOverviewScript.isOverview(_:markdown:)`, for where the body is
    /// in hand), and the carrier is the overview's other half: the two are
    /// saved and deleted together.
    static func isOverview(
        _ artifact: ArtifactRecord,
        hasCarrier: (_ carrierSourceID: String) throws -> Bool
    ) rethrows -> Bool {
        if artifact.kind == .audioOverview { return true }
        guard artifact.kind == nil, !artifact.isLinked else { return false }
        return try hasCarrier(carrierSourceID(artifactID: artifact.id))
    }

    /// The carrier as an article-typed source with the script as its text,
    /// ready to listen to, search and sync. Article, as an explainer is: the
    /// listen path reads an article's own text, and the spoken-script prefix
    /// keeps the preparation pass off it
    /// (`TextToSpeechPreparationPolicy.isSpokenScript`). Its title is the
    /// writer's spoken title, which is what Now Playing and Siri see.
    static func carrierSource(artifactID: String, title: String, script: String) -> StudioArticle {
        var article = StudioArticle(
            url: AudioOverviewScript.url(artifactID: artifactID),
            title: title,
            sourceType: .article,
            discoveryOrigin: .manual
        )
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        article.domain = AudioOverviewScript.domain
        article.content = script
        article.wordCount = ExplainerScript.wordCount(of: script)
        article.state = .ready
        return article
    }

    /// What a source is, as the writer is told and a listener would say it:
    /// the words every notebook writer uses (`NotebookSourceKind`).
    static func spokenKind(_ type: StudioSourceType) -> String {
        NotebookSourceKind.label(type)
    }
}

// MARK: - Request, notebook and plan

/// One Make: the notebook, the learner's options, and — from MCP — the
/// sources to write from when the caller names them.
struct AudioOverviewRequest: Equatable, Sendable {
    var notebookID: String
    var options: AudioOverviewOptions
    /// The sources to write from, in order; nil reads the notebook's ticked sources
    /// (`AudioOverviewGeneratorService.notebookSourceIDs`).
    var sourceIDs: [String]? = nil
}

/// The notebook as the writer will read it, loaded once per options sheet:
/// every source with text, its stored ideas when they were taken from that
/// same text, and the sources set aside with the reason. The reading every
/// notebook writer shares (`NotebookSourceLoader`).
typealias AudioOverviewNotebook = NotebookSourceSet

/// The route the writing runs on — the window each request must fit, the
/// reasoning-aware output ceiling and the list price — sized for the
/// overview's writer (`LiveAudioOverviewModelBackend.currentRoute`).
typealias AudioOverviewRoute = NotebookWritingRoute

/// What the writing — the script and any condensing — will cost, before
/// anything is sent.
typealias AudioOverviewTextCost = NotebookWritingCost

/// One consecutive part of a source the condensing pass retells.
struct AudioOverviewCondensePart: Sendable, Equatable {
    let sourceID: String
    let sourceTitle: String
    let sourceType: StudioSourceType
    /// 1-based, of `count`.
    let index: Int
    let count: Int
    let text: String
    let targetWords: Int

    /// The most words one condensing call is asked for. A source that needs
    /// more room is condensed in more parts.
    static let maximumTargetWords = NotebookSourceCondensing.maximumTargetWords
    /// The response budget of the longest call, for sizing the condenser's
    /// window before the parts are known.
    static let largestMaxTokens = NotebookSourceCondensing.largestMaxTokens

    static func maxTokens(forTargetWords words: Int) -> Int {
        NotebookSourceCondensing.maxTokens(forTargetWords: words)
    }

    var maxTokens: Int { Self.maxTokens(forTargetWords: targetWords) }

    var userMessage: String {
        var lines = [
            "Source: \(sourceTitle)",
            "Kind: \(GeneratedAudioOverview.spokenKind(sourceType))",
        ]
        if count > 1 {
            lines.append("Part \(index) of \(count), in order; the other parts are condensed separately.")
        }
        lines.append("Target length: about \(targetWords) words.")
        lines.append("")
        lines.append("Text:")
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}

/// How the overview will be written: which sources are read whole, from
/// their ideas or condensed, the condensing calls that takes, what it costs,
/// and the turn's fixed part. Pure: built from a loaded notebook, options and
/// a route, so the sheet re-plans on every change of option without reading
/// the library again.
struct AudioOverviewPlan: Sendable {
    struct Source: Sendable, Equatable {
        let candidate: AudioOverviewNotebook.Candidate
        let readAs: AudioOverviewReadAs
        /// Characters the condensed account is asked to run to; nil unless condensed.
        let condensedTargetCharacters: Int?
        /// The condensing calls, in the source's order; empty unless condensed.
        let parts: [AudioOverviewCondensePart]
    }

    let request: AudioOverviewRequest
    let notebookTitle: String
    let instructions: String?
    let skipped: [AudioOverviewNotebook.Skipped]
    let route: AudioOverviewRoute
    let system: String
    let sources: [Source]
    let writingCost: AudioOverviewTextCost

    var options: AudioOverviewOptions { request.options }

    /// The script's upper length in characters, for the audio quote: the
    /// most words the writer is asked for at English prose's characters per
    /// word, which the narration price is quoted against.
    var expectedScriptCharacters: Int {
        Int(Double(options.wordRange.upperBound) * ArticleSpeechCostEstimate.fallbackCharactersPerWord)
    }

    var condensingCallCount: Int { sources.reduce(0) { $0 + $1.parts.count } }

    var readings: [AudioOverviewSourceReading] {
        sources.map {
            AudioOverviewSourceReading(sourceID: $0.candidate.source.id, title: $0.candidate.source.title, readAs: $0.readAs)
        }
    }

    /// "12 of 14 sources · 2 read from their ideas · 1 condensed · 2 left out"
    var sourcesSummary: String {
        ReportPlan.sourcesLine(
            included: sources.count,
            skipped: skipped.count,
            readFromIdeas: sources.filter { $0.readAs == .ideas }.count,
            condensed: sources.filter { $0.readAs == .condensed }.count
        )
    }
}

/// Where a run is, for the pending row and `list_running_ai_work`.
enum AudioOverviewStage: Equatable, Sendable {
    case reading(sourceCount: Int)
    case condensing(done: Int, total: Int, sourceCount: Int)
    case writing
    case saving

    var label: String {
        switch self {
        case .reading(let count):
            return "Reading \(count == 1 ? "1 source" : "\(count) sources")"
        case .condensing(let done, let total, let sources):
            let noun = sources == 1 ? "1 long source" : "\(sources) long sources"
            return total > 1 ? "Condensing \(noun) (\(min(done + 1, total)) of \(total))" : "Condensing \(noun)"
        case .writing:
            return "Writing the script"
        case .saving:
            return "Saving"
        }
    }
}

struct AudioOverviewResult: Sendable {
    let artifact: ArtifactRecord
    let carrier: StudioArticle
    let settings: AudioOverviewSettings
}

enum AudioOverviewGenerationError: LocalizedError, Equatable {
    case notebookNotFound(String)
    case sourceNotInNotebook([String])
    case noSources(String)
    case noModelConfigured
    case doesNotFit(model: String, sourceCount: Int)
    case condensedTooLong(model: String)
    /// The window has no room for even one condensing request's
    /// instructions; there is nothing to size a part against.
    case windowTooSmall(model: String)
    /// One condensing request would not fit the window as sent, so the
    /// central one-shot trim would cut its text; refused instead.
    case partTooLong(model: String, title: String)
    case emptyScript
    case emptyCondensedAccount(String)

    var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id):
            return "No Notebook with id \(id) is in the library."
        case .sourceNotInNotebook(let ids):
            return "Not in this Notebook: \(ids.joined(separator: ", ")). An audio overview is written from the Notebook's own sources."
        case .noSources(let title):
            return "None of the sources in \(title) has text to write an audio overview from yet."
        case .noModelConfigured:
            return "No model is configured for Audio Overview Writing. Sign in and check Settings › AI Models."
        case .doesNotFit(let model, let count):
            let subject = count == 1 ? "The source does not" : "\(count) sources do not"
            return "\(subject) fit \(model)'s context window even condensed. Untick some sources, or choose a model with a larger window for Audio Overview Writing."
        case .condensedTooLong(let model):
            return "The condensed sources came back too long to fit \(model)'s context window together. Untick a source, or choose a model with a larger window for Audio Overview Writing."
        case .windowTooSmall(let model):
            return "\(model)'s context window is too small to condense any source in. Choose a model with a larger window for Audio Overview Writing."
        case .partTooLong(let model, let title):
            return "A part of \"\(title)\" is too long for \(model)'s context window to condense, and nothing is cut. Choose a model with a larger window for Audio Overview Writing."
        case .emptyScript:
            return "The writer returned no script."
        case .emptyCondensedAccount(let title):
            return "The condensing pass returned nothing for \"\(title)\"."
        }
    }
}

/// The model side, behind a protocol so the storage side and the planner can
/// be pinned in tests with canned text.
protocol AudioOverviewModelBackend: Sendable {
    /// `route` is the plan's: every call goes to the model the plan was
    /// sized and priced against.
    func condense(_ part: AudioOverviewCondensePart, route: AudioOverviewRoute) async throws -> String
    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: AudioOverviewRoute
    ) async throws -> AudioOverviewDraft
}

/// Writes with the learner's Audio Overview Writing route, as the plan
/// resolved it.
struct LiveAudioOverviewModelBackend: AudioOverviewModelBackend {
    let aiService: AIService

    func condense(_ part: AudioOverviewCondensePart, route: AudioOverviewRoute) async throws -> String {
        guard let config = route.config else {
            throw AudioOverviewGenerationError.noModelConfigured
        }
        return try await aiService.condenseForAudioOverview(part, config: config)
    }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: AudioOverviewRoute
    ) async throws -> AudioOverviewDraft {
        guard let config = route.config else {
            throw AudioOverviewGenerationError.noModelConfigured
        }
        return try await aiService.writeAudioOverview(
            system: system,
            user: user,
            notebookTitle: notebookTitle,
            notebookID: notebookID,
            config: config
        )
    }

    /// The route plans are priced and sized against — the learner's Audio
    /// Overview Writing setting, sized for the overview's writer and its
    /// condensing calls; nil when no model is configured (signed out, out of
    /// credits, or a broken setting).
    static func currentRoute() -> AudioOverviewRoute? {
        KeychainService.resolveConfig(for: .audioOverviewWriting).map {
            NotebookWritingRoute.live(
                $0,
                writerMaxTokens: AIService.audioOverviewWriterMaxTokens,
                condenserMaxTokens: AudioOverviewCondensePart.largestMaxTokens
            )
        }
    }
}

// MARK: - The service

/// A notebook's audio overview: read its sources, fit them to the writing
/// route's window — a source that does not fit is read from its stored ideas
/// or a condensed account of its whole text, and the prompt, the price and
/// the result say so; nothing is ever cut — write one spoken script, and
/// save it as an Artifact homed on the notebook with its hidden carrier
/// source. Audio is not this service's job: the caller hands the carrier to
/// the same text-to-speech path every source uses, so the narration's price is
/// asked by the code that already asks it.
///
/// Runs off the main actor. A run's calls share one activity id, so
/// Settings › AI activity shows the overview as one line.
struct AudioOverviewGeneratorService: Sendable {
    let storage: StorageService
    let backend: any AudioOverviewModelBackend

    /// How many condensing calls run at once.
    static let condensingConcurrency = 3

    init(storage: StorageService, backend: any AudioOverviewModelBackend) {
        self.storage = storage
        self.backend = backend
    }

    // MARK: The ticked-sources seam

    /// The sources an overview is written from when the caller names none —
    /// the one seam every path reads (the Studio sheet, the coordinator and
    /// `generate_audio_overview`), shared with every notebook writer: the
    /// notebook's own ticked sources (`NotebookSourceLoader.notebookSourceIDs`).
    static func notebookSourceIDs(notebookID: String, storage: StorageService) async throws -> [String] {
        try await NotebookSourceLoader.notebookSourceIDs(notebookID: notebookID, storage: storage)
    }

    static func tickedSourceIDs(pool: [String], notebookID: String) -> [String] {
        NotebookSourceLoader.tickedSourceIDs(pool: pool, notebookID: notebookID)
    }

    // MARK: Load

    /// Reads the notebook and every selected source's text and ideas
    /// (`NotebookSourceLoader.load`). Sources with no text, spoken scripts,
    /// and sources kept from AI are set aside with the reason. `sourceIDs`
    /// must all be the notebook's own.
    func load(notebookID: String, sourceIDs: [String]? = nil) async throws -> AudioOverviewNotebook {
        do {
            return try await NotebookSourceLoader.load(notebookID: notebookID, sourceIDs: sourceIDs, storage: storage)
        } catch let error as NotebookSourceLoadError {
            switch error {
            case .notebookNotFound(let id): throw AudioOverviewGenerationError.notebookNotFound(id)
            case .sourceNotInNotebook(let ids): throw AudioOverviewGenerationError.sourceNotInNotebook(ids)
            }
        }
    }

    /// A source's stored ideas, written out for the writer, when they speak
    /// for its whole text (`NotebookSourceLoader.currentIdeas`).
    static func currentIdeas(
        _ ideas: [SourceIdea]?,
        sourceID: String,
        storedText: String,
        storage: StorageService
    ) async throws -> String? {
        try await NotebookSourceLoader.currentIdeas(ideas, sourceID: sourceID, storedText: storedText, storage: storage)
    }

    /// A source's ideas as the writer reads them: each statement, and what a
    /// good recall of it holds.
    static func ideasText(_ ideas: [SourceIdea]) -> String {
        NotebookSourceLoader.ideasText(ideas)
    }

    // MARK: Plan

    /// Fits the notebook to the route and prices the writing. Throws when
    /// even every source read from its ideas or condensed to the least that
    /// is still worth reading cannot fit the window.
    static func plan(
        _ notebook: AudioOverviewNotebook,
        request: AudioOverviewRequest,
        route: AudioOverviewRoute,
        system: String = AITask.audioOverviewWriting.effectivePrompt ?? Prompts.audioOverviewWriter
    ) throws -> AudioOverviewPlan {
        guard !notebook.candidates.isEmpty else {
            throw AudioOverviewGenerationError.noSources(notebook.title)
        }
        let options = request.options
        // The turn with every source's text left out: what the request
        // carries before any source is read.
        let skeleton = writerTurn(notebook: notebook, options: options, bodies: notebook.candidates.map { ($0, .whole, "") })
        let fixed = system.count + skeleton.count + Self.requestOverheadCharacters
            // Each header can lengthen by a few characters when its source is
            // read another way ("Read: condensed", "Condensed account:").
            + notebook.candidates.count * Self.headerSlackCharacters

        let choices = try AudioOverviewBudget.choose(
            sources: notebook.candidates.map {
                AudioOverviewBudget.Length(id: $0.source.id, whole: $0.text.count, ideas: $0.ideas?.count)
            },
            fixedCharacters: fixed,
            budget: route.writerInputBudget,
            model: route.modelLabel
        )

        var sources: [AudioOverviewPlan.Source] = []
        for candidate in notebook.candidates {
            let choice = choices[candidate.source.id] ?? .init(readAs: .whole, targetCharacters: nil)
            let parts = choice.readAs == .condensed
                ? try condensingParts(
                    of: candidate,
                    targetCharacters: choice.targetCharacters ?? AudioOverviewBudget.minimumCondensedCharacters,
                    route: route
                )
                : []
            sources.append(.init(
                candidate: candidate,
                readAs: choice.readAs,
                condensedTargetCharacters: choice.readAs == .condensed ? choice.targetCharacters : nil,
                parts: parts
            ))
        }

        // The writer's request as it will go, with each condensed account at
        // its target length.
        let writerInputCharacters = fixed + sources.reduce(0) { total, source in
            switch source.readAs {
            case .whole: return total + source.candidate.text.count
            case .ideas: return total + (source.candidate.ideas?.count ?? 0)
            case .condensed: return total + (source.condensedTargetCharacters ?? 0)
            }
        }
        let writingCost = cost(
            writerInputCharacters: writerInputCharacters,
            options: options,
            parts: sources.flatMap(\.parts),
            route: route
        )
        return AudioOverviewPlan(
            request: request,
            notebookTitle: notebook.title,
            instructions: notebook.instructions,
            skipped: notebook.skipped,
            route: route,
            system: system,
            sources: sources,
            writingCost: writingCost
        )
    }

    /// The structural characters a provider adds around one turn, the same
    /// allowance `AIService.budgetedChatRequest` counts.
    static let requestOverheadCharacters = NotebookSourceCondensing.requestOverheadCharacters
    static let headerSlackCharacters = 32

    /// The writer's turn for these bodies.
    static func writerTurn(
        notebook: AudioOverviewNotebook,
        options: AudioOverviewOptions,
        bodies: [(AudioOverviewNotebook.Candidate, AudioOverviewReadAs, String)]
    ) -> String {
        AudioOverviewWriterTurn.userMessage(
            notebookTitle: notebook.title,
            instructions: notebook.instructions,
            options: options,
            sources: bodies.map { candidate, readAs, body in
                AudioOverviewTurnSource(
                    title: candidate.source.title,
                    kind: GeneratedAudioOverview.spokenKind(candidate.source.sourceType),
                    author: candidate.source.displayAuthor,
                    venue: candidate.source.journal,
                    year: candidate.source.publishedYear,
                    readAs: readAs,
                    text: body
                )
            }
        )
    }

    /// A source's condensing calls: its whole text in consecutive parts, each
    /// small enough for one condensing request, each asked for its share of
    /// the target (`NotebookSourceCondensing.slices`). Never a sample: every
    /// character is in exactly one part. Throws when the window has no room
    /// for a part at all.
    static func condensingParts(
        of candidate: AudioOverviewNotebook.Candidate,
        targetCharacters: Int,
        route: AudioOverviewRoute
    ) throws -> [AudioOverviewCondensePart] {
        let slices: [NotebookSourceCondensing.Slice]
        do {
            slices = try NotebookSourceCondensing.slices(
                of: candidate.text,
                targetCharacters: targetCharacters,
                condenserInputBudget: route.condenserInputBudget,
                promptCharacters: Prompts.audioOverviewCondenser.count
            )
        } catch is NotebookSourceCondensing.WindowTooSmall {
            throw AudioOverviewGenerationError.windowTooSmall(model: route.modelLabel)
        }
        return slices.map { slice in
            AudioOverviewCondensePart(
                sourceID: candidate.source.id,
                sourceTitle: candidate.source.title,
                sourceType: candidate.source.sourceType,
                index: slice.index,
                count: slice.count,
                text: slice.text,
                targetWords: slice.targetWords
            )
        }
    }

    /// `text` in exactly `count` consecutive pieces of about equal length
    /// (`NotebookSourceCondensing.splitConsecutively`). The pieces joined
    /// give back the text.
    static func splitConsecutively(_ text: String, into count: Int) -> [String] {
        NotebookSourceCondensing.splitConsecutively(text, into: count)
    }

    /// The writing's price: the writer's request, and each condensing call.
    static func cost(
        writerInputCharacters: Int,
        options: AudioOverviewOptions,
        parts: [AudioOverviewCondensePart],
        route: AudioOverviewRoute
    ) -> AudioOverviewTextCost {
        let perToken = AIService.approxCharsPerToken
        // A spoken word runs to about 1.4 tokens; the JSON around it is small.
        func tokens(words: Int) -> Int { Int(Double(words) * 1.4) + 200 }

        var inputTokens = writerInputCharacters / perToken
        var expected = tokens(words: options.wordRange.upperBound)
        var maximum = route.outputCeiling(requested: AIService.audioOverviewWriterMaxTokens)
        var expectedUSD = route.usd(inputTokens: inputTokens, outputTokens: expected)
        var maximumUSD = route.usd(inputTokens: inputTokens, outputTokens: maximum)
        for part in parts {
            let input = (Prompts.audioOverviewCondenser.count + part.userMessage.count + requestOverheadCharacters) / perToken
            let partExpected = tokens(words: part.targetWords)
            let partMaximum = route.outputCeiling(requested: part.maxTokens)
            inputTokens += input
            expected += partExpected
            maximum += partMaximum
            expectedUSD = expectedUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: partExpected).map { total + $0 } }
            maximumUSD = maximumUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: partMaximum).map { total + $0 } }
        }
        return AudioOverviewTextCost(
            requestCount: 1 + parts.count,
            inputTokens: inputTokens,
            expectedOutputTokens: expected,
            maximumOutputTokens: maximum,
            expectedUSD: expectedUSD,
            maximumUSD: maximumUSD
        )
    }

    // MARK: Run

    /// Condenses what the plan condenses, writes the script, and saves the
    /// overview under `artifactID` — reserved by the caller, so an MCP answer
    /// and a pending row can name the overview and its carrier before they
    /// exist. Checks for cancellation before it saves, so a stopped run leaves
    /// nothing behind.
    func run(
        _ plan: AudioOverviewPlan,
        artifactID: String = UUID().uuidString.lowercased(),
        onStage: @escaping @Sendable (AudioOverviewStage) async -> Void = { _ in }
    ) async throws -> AudioOverviewResult {
        let workflowID = UUID().uuidString
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await runStages(plan, artifactID: artifactID, onStage: onStage)
            }
        }
    }

    private func runStages(
        _ plan: AudioOverviewPlan,
        artifactID: String,
        onStage: @escaping @Sendable (AudioOverviewStage) async -> Void
    ) async throws -> AudioOverviewResult {
        await onStage(.reading(sourceCount: plan.sources.count))
        let accounts = try await condense(plan, onStage: onStage)
        try Task.checkCancellation()

        let notebook = AudioOverviewNotebook(
            notebookID: plan.request.notebookID,
            title: plan.notebookTitle,
            instructions: plan.instructions,
            candidates: plan.sources.map(\.candidate),
            skipped: plan.skipped
        )
        let bodies = plan.sources.map { source -> (AudioOverviewNotebook.Candidate, AudioOverviewReadAs, String) in
            switch source.readAs {
            case .whole: return (source.candidate, .whole, source.candidate.text)
            case .ideas: return (source.candidate, .ideas, source.candidate.ideas ?? "")
            case .condensed: return (source.candidate, .condensed, accounts[source.candidate.source.id] ?? "")
            }
        }
        let user = Self.writerTurn(notebook: notebook, options: plan.options, bodies: bodies)
        // The one-shot path trims a request that overflows the window, which
        // would cut the sources silently. The plan sized the turn to fit;
        // a condensed account that came back longer than asked is the one
        // way it can still overflow, and that is refused, not cut.
        if plan.route.writerInputBudget != nil {
            let budgeted = AIService.budgetedOneShotRequest(
                provider: plan.route.provider,
                model: plan.route.model,
                system: plan.system,
                user: user,
                requestedMaxTokens: AIService.audioOverviewWriterMaxTokens
            )
            guard budgeted.system == plan.system, budgeted.user == user else {
                throw AudioOverviewGenerationError.condensedTooLong(model: plan.route.modelLabel)
            }
        }

        await onStage(.writing)
        let draft = try await backend.write(
            system: plan.system,
            user: user,
            notebookTitle: plan.notebookTitle,
            notebookID: plan.request.notebookID,
            route: plan.route
        )
        // A cancelled run that the provider still answered must not land an
        // overview the learner has already given up on.
        try Task.checkCancellation()
        guard draft.isUsable else { throw AudioOverviewGenerationError.emptyScript }

        await onStage(.saving)
        let title = Self.title(of: draft, notebookTitle: plan.notebookTitle)
        let settings = AudioOverviewSettings(
            format: plan.options.format,
            length: plan.options.effectiveLength,
            focus: plan.options.trimmedFocus,
            audioSourceID: GeneratedAudioOverview.carrierSourceID(artifactID: artifactID),
            sources: plan.readings,
            model: plan.route.model,
            // Whole seconds, as the recipe stores it, so the settings handed
            // back equal the ones read from the saved overview.
            madeAt: Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
        )
        let carrier = GeneratedAudioOverview.carrierSource(artifactID: artifactID, title: title, script: draft.script)
        let artifact = try await storage.saveAudioOverview(
            artifactID: artifactID,
            title: title,
            notebookID: plan.request.notebookID,
            sourceIDs: plan.sources.map(\.candidate.source.id),
            markdown: try AudioOverviewScript.markdown(settings: settings),
            carrier: carrier
        )
        return AudioOverviewResult(artifact: artifact, carrier: carrier, settings: settings)
    }

    /// Every condensed source's account, by source id: its parts condensed a
    /// few at a time (`NotebookSourceCondensing.condenseAll`) and joined in
    /// order.
    private func condense(
        _ plan: AudioOverviewPlan,
        onStage: @escaping @Sendable (AudioOverviewStage) async -> Void
    ) async throws -> [String: String] {
        let parts = plan.sources.flatMap(\.parts)
        guard !parts.isEmpty else { return [:] }
        let sourceCount = plan.sources.filter { !$0.parts.isEmpty }.count
        await onStage(.condensing(done: 0, total: parts.count, sourceCount: sourceCount))
        let backend = backend
        let route = plan.route
        let total = parts.count
        let results = try await NotebookSourceCondensing.condenseAll(
            parts,
            concurrency: Self.condensingConcurrency,
            condense: { part in try await backend.condense(part, route: route) },
            onProgress: { done in await onStage(.condensing(done: done, total: total, sourceCount: sourceCount)) }
        )
        var accounts: [String: [String]] = [:]
        for (index, part) in parts.enumerated() {
            accounts[part.sourceID, default: []].append(results[index])
        }
        return accounts.mapValues { $0.joined(separator: "\n\n") }
    }

    /// The overview's title: the writer's, or the notebook's when the writer
    /// gave none.
    static func title(of draft: AudioOverviewDraft, notebookTitle: String) -> String {
        let written = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        return "\(notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)) — audio overview"
    }
}

// MARK: - Fitting the window

/// Which sources the writer reads whole, from their ideas, or condensed, so
/// the request fits the window: every notebook writer's fit
/// (`NotebookSourceBudget`), refused in the overview's words.
enum AudioOverviewBudget {
    typealias Length = NotebookSourceBudget.Length
    typealias Choice = NotebookSourceBudget.Choice

    /// The least a condensed account is asked for: below this a source is
    /// hardly read at all.
    static let minimumCondensedCharacters = NotebookSourceBudget.minimumCondensedCharacters
    /// Condensed accounts are asked for less than the room left, since a
    /// model runs a little past a target length.
    static let condensedShareOfRoom = NotebookSourceBudget.condensedShareOfRoom

    static func choose(
        sources: [Length],
        fixedCharacters: Int,
        budget: Int?,
        model: String
    ) throws -> [String: Choice] {
        do {
            return try NotebookSourceBudget.choose(
                sources: sources,
                fixedCharacters: fixedCharacters,
                budget: budget,
                model: model
            )
        } catch let refusal as NotebookSourceBudget.DoesNotFit {
            throw AudioOverviewGenerationError.doesNotFit(model: refusal.model, sourceCount: refusal.sourceCount)
        }
    }
}
