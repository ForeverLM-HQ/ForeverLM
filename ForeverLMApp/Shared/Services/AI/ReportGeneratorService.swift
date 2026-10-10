import Foundation

// MARK: - Request, notebook and plan

/// One Make: the notebook, the learner's options, and — from MCP — the
/// sources to write from when the caller names them.
struct ReportRequest: Equatable, Sendable {
    var notebookID: String
    var options: ReportOptions
    /// The sources to write from, in order; nil reads the notebook's ticked
    /// sources (`NotebookSourceLoader.notebookSourceIDs`).
    var sourceIDs: [String]? = nil
}

/// The notebook as the report's writer will read it: its selected sources,
/// read as every notebook writer reads them (`NotebookSourceSet`), and the
/// Docs a feedback report can be about.
struct ReportNotebook: Sendable {
    /// A Doc of the notebook, by title, that a feedback report can be about.
    struct Document: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
    }

    let sources: NotebookSourceSet
    /// The notebook's current Markdown Docs and Google Docs, newest first.
    let documents: [Document]

    var notebookID: String { sources.notebookID }
    var title: String { sources.title }

    /// What an id names as the document a feedback report is about: one of
    /// the selected sources (one set aside for having no text included, so
    /// the plan can say why), or one of the notebook's Docs. Nil otherwise.
    func subject(id rawID: String) -> ReportSubject? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = sources.candidates.first(where: { $0.source.id == id }) {
            return ReportSubject(kind: .source, id: id, title: candidate.source.title)
        }
        if let skipped = sources.skipped.first(where: { $0.sourceID == id }) {
            return ReportSubject(kind: .source, id: id, title: skipped.title)
        }
        if let document = documents.first(where: { $0.id == id }) {
            return ReportSubject(kind: .doc, id: id, title: document.title)
        }
        return nil
    }
}

/// One consecutive part of a source the report's condensing pass retells.
struct ReportCondensePart: Sendable, Equatable {
    let sourceID: String
    let sourceTitle: String
    let sourceType: StudioSourceType
    /// 1-based, of `count`.
    let index: Int
    let count: Int
    let text: String
    let targetWords: Int

    /// The response budget of the longest call, for sizing the condenser's
    /// window before the parts are known.
    static let largestMaxTokens = NotebookSourceCondensing.largestMaxTokens

    var maxTokens: Int { NotebookSourceCondensing.maxTokens(forTargetWords: targetWords) }

    var userMessage: String {
        var lines = [
            "Source: \(sourceTitle)",
            "Kind: \(NotebookSourceKind.label(sourceType))",
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

/// How the report will be written: which sources are read whole, from their
/// ideas or condensed, the condensing calls that takes, what it costs, the
/// document a feedback report is about, and the turn's fixed part. Pure:
/// built from a loaded notebook, options and a route, so the sheet re-plans
/// on every change of option without reading the library again.
struct ReportPlan: Sendable {
    struct Source: Sendable, Equatable {
        /// Its marker in the turn: `[S<number>]`.
        let number: Int
        let candidate: NotebookSourceSet.Candidate
        let readAs: NotebookSourceReadAs
        /// Characters the condensed account is asked to run to; nil unless condensed.
        let condensedTargetCharacters: Int?
        /// The condensing calls, in the source's order; empty unless condensed.
        let parts: [ReportCondensePart]
        /// Whether this is the document a feedback report is about, read whole.
        let isSubject: Bool
    }

    let request: ReportRequest
    let notebookTitle: String
    let instructions: String?
    let skipped: [NotebookSourceSet.Skipped]
    /// The Doc a feedback report is about, read whole beside the sources.
    let subjectDocument: ReportSubjectDocument?
    let route: NotebookWritingRoute
    let system: String
    let sources: [Source]
    let writingCost: NotebookWritingCost

    var options: ReportOptions { request.options }

    var condensingCallCount: Int { sources.reduce(0) { $0 + $1.parts.count } }

    /// The sources in marker order, as the citations name them.
    var citationSources: [ReportCitations.Source] {
        sources.map { ReportCitations.Source(id: $0.candidate.source.id, title: $0.candidate.source.title, readAs: $0.readAs) }
    }

    /// The recipe the report will close with.
    var recipe: ReportRecipe {
        ReportRecipe(
            format: options.format,
            sourceCount: sources.count,
            subjectTitle: options.effectiveSubject.map { subjectDocument?.title ?? $0.title },
            subjectIsDocument: subjectDocument != nil,
            note: options.trimmedInstruction ?? options.trimmedFocus
        )
    }

    /// "6 of 8 sources · 1 read from its ideas · 1 condensed · 2 left out"
    var sourcesSummary: String {
        let total = sources.count + skipped.count
        var parts = [total == sources.count
            ? (sources.count == 1 ? "1 source" : "\(sources.count) sources")
            : "\(sources.count) of \(total) sources"]
        let ideas = sources.filter { $0.readAs == .ideas }.count
        let condensed = sources.filter { $0.readAs == .condensed }.count
        if ideas > 0 { parts.append("\(ideas) read from \(ideas == 1 ? "its" : "their") ideas") }
        if condensed > 0 { parts.append("\(condensed) condensed") }
        if !skipped.isEmpty { parts.append("\(skipped.count) left out") }
        return parts.joined(separator: " · ")
    }
}

/// Where a run is, for the pending row and `list_running_ai_work`.
enum ReportStage: Equatable, Sendable {
    case reading(sourceCount: Int)
    case condensing(done: Int, total: Int, sourceCount: Int)
    case writing(ReportFormat)
    case saving

    var label: String {
        switch self {
        case .reading(let count):
            return "Reading \(count == 1 ? "1 source" : "\(count) sources")"
        case .condensing(let done, let total, let sources):
            let noun = sources == 1 ? "1 long source" : "\(sources) long sources"
            return total > 1 ? "Condensing \(noun) (\(min(done + 1, total)) of \(total))" : "Condensing \(noun)"
        case .writing(let format):
            return "Writing \(format.writingNoun)"
        case .saving:
            return "Saving"
        }
    }
}

struct ReportResult: Sendable {
    let artifact: ArtifactRecord
    let recipe: ReportRecipe
    /// The sources the report cites, in order of first citation.
    let citedSourceIDs: [String]
    /// Markers the writer wrote for a number it was not given; dropped.
    let unresolvedMarkers: [String]
}

enum ReportGenerationError: LocalizedError, Equatable {
    case notebookNotFound(String)
    /// An archived notebook, or a team's the account can only read: nothing
    /// is filed in it.
    case notebookTakesNoReport(title: String, reason: String)
    case sourceNotInNotebook([String])
    case noSources(String)
    case noModelConfigured
    case instructionRequired
    case subjectRequired
    case subjectNotInNotebook(String)
    case subjectHasNoText(String)
    /// The source named as the feedback's document was set aside when the
    /// notebook was read, with the reason (no text yet, kept from AI).
    case subjectSetAside(title: String, reason: String)
    /// The document a feedback report is about does not fit the window
    /// whole; it is the one thing the writer must read whole.
    case subjectTooLong(model: String, title: String)
    case doesNotFit(model: String, sourceCount: Int)
    case condensedTooLong(model: String)
    /// The window has no room for even one condensing request's
    /// instructions; there is nothing to size a part against.
    case windowTooSmall(model: String)
    /// One condensing request would not fit the window as sent, so the
    /// central one-shot trim would cut its text; refused instead.
    case partTooLong(model: String, title: String)
    case emptyReport
    case emptyCondensedAccount(String)

    var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id):
            return "No Notebook with id \(id) is in the library."
        case .notebookTakesNoReport(let title, let reason):
            return "A report can\u{2019}t be made in \u{2018}\(title)\u{2019}: \(reason)."
        case .sourceNotInNotebook(let ids):
            return "Not in this Notebook: \(ids.joined(separator: ", ")). A report is written from the Notebook's own sources."
        case .noSources(let title):
            return "None of the sources in \(title) has text to write a report from yet."
        case .noModelConfigured:
            return "No model is configured for Report Writing. Sign in and check Settings › AI Models."
        case .instructionRequired:
            return "A custom report needs an instruction: what the report should be."
        case .subjectRequired:
            return "Feedback on a document needs the document: one of the Notebook's sources or Pages."
        case .subjectNotInNotebook(let id):
            return "\(id) is not one of this Notebook's sources or Pages."
        case .subjectHasNoText(let title):
            return "\u{201C}\(title)\u{201D} has no text to give feedback on yet."
        case .subjectSetAside(let title, let reason):
            return "\u{201C}\(title)\u{201D} can\u{2019}t be read for feedback. \(reason)"
        case .subjectTooLong(let model, let title):
            return "\u{201C}\(title)\u{201D} is too long for \(model)'s context window to read whole, and nothing is cut. Choose a model with a larger window for Report Writing."
        case .doesNotFit(let model, let count):
            let subject = count == 1 ? "The source does not" : "\(count) sources do not"
            return "\(subject) fit \(model)'s context window even condensed. Untick some sources, or choose a model with a larger window for Report Writing."
        case .condensedTooLong(let model):
            return "The condensed sources came back too long to fit \(model)'s context window together. Untick a source, or choose a model with a larger window for Report Writing."
        case .windowTooSmall(let model):
            return "\(model)'s context window is too small to condense any source in. Choose a model with a larger window for Report Writing."
        case .partTooLong(let model, let title):
            return "A part of \"\(title)\" is too long for \(model)'s context window to condense, and nothing is cut. Choose a model with a larger window for Report Writing."
        case .emptyReport:
            return "The writer returned no report."
        case .emptyCondensedAccount(let title):
            return "The condensing pass returned nothing for \"\(title)\"."
        }
    }
}

/// The model side, behind a protocol so the storage side and the planner can
/// be pinned in tests with canned text.
protocol ReportModelBackend: Sendable {
    /// `route` is the plan's: every call goes to the model the plan was
    /// sized and priced against.
    func condense(_ part: ReportCondensePart, route: NotebookWritingRoute) async throws -> String
    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: NotebookWritingRoute
    ) async throws -> ReportDraft
}

/// Writes with the learner's Report Writing route, as the plan resolved it.
struct LiveReportModelBackend: ReportModelBackend {
    let aiService: AIService

    func condense(_ part: ReportCondensePart, route: NotebookWritingRoute) async throws -> String {
        guard let config = route.config else {
            throw ReportGenerationError.noModelConfigured
        }
        return try await aiService.condenseForReport(part, config: config)
    }

    func write(
        system: String,
        user: String,
        notebookTitle: String,
        notebookID: String,
        route: NotebookWritingRoute
    ) async throws -> ReportDraft {
        guard let config = route.config else {
            throw ReportGenerationError.noModelConfigured
        }
        return try await aiService.writeReport(
            system: system,
            user: user,
            notebookTitle: notebookTitle,
            notebookID: notebookID,
            config: config
        )
    }

    /// The route plans are priced and sized against — the learner's Report
    /// Writing setting, sized for the report's writer and its condensing
    /// calls; nil when no model is configured (signed out, out of credits,
    /// or a broken setting).
    static func currentRoute() -> NotebookWritingRoute? {
        KeychainService.resolveConfig(for: .reportWriting).map {
            NotebookWritingRoute.live(
                $0,
                writerMaxTokens: AIService.reportWriterMaxTokens,
                condenserMaxTokens: ReportCondensePart.largestMaxTokens
            )
        }
    }
}

// MARK: - The service

/// A notebook's report: read its ticked sources (and, for feedback on one of
/// its Docs, that Doc), fit them to the writing route's window — a source
/// that does not fit is read from its stored ideas or a condensed account of
/// its whole text, and the prompt, the price and the Doc say so; nothing is
/// ever cut — write the report, turn its markers into the Doc's citations,
/// and save it as a Doc homed in the notebook, grounded on the sources it was
/// written from, closing with its Sources and recipe.
///
/// Runs off the main actor. A run's calls share one activity id, so
/// Settings › AI activity shows the report as one line.
struct ReportGeneratorService: Sendable {
    let storage: StorageService
    let backend: any ReportModelBackend

    /// How many condensing calls run at once.
    static let condensingConcurrency = 3
    /// The structural characters a provider adds around one turn.
    static let requestOverheadCharacters = NotebookSourceCondensing.requestOverheadCharacters
    /// Room for a header to lengthen when its source is read another way
    /// ("Read: condensed", "Condensed account:").
    static let headerSlackCharacters = 32

    init(storage: StorageService, backend: any ReportModelBackend) {
        self.storage = storage
        self.backend = backend
    }

    // MARK: Load

    /// Reads the notebook — every selected source's text and ideas, set-aside
    /// ones with the reason (`NotebookSourceLoader.load`) — and the Docs a
    /// feedback report can be about. `sourceIDs` must all be in the notebook.
    func load(notebookID: String, sourceIDs: [String]? = nil) async throws -> ReportNotebook {
        let sources: NotebookSourceSet
        do {
            sources = try await NotebookSourceLoader.load(notebookID: notebookID, sourceIDs: sourceIDs, storage: storage)
        } catch let error as NotebookSourceLoadError {
            switch error {
            case .notebookNotFound(let id): throw ReportGenerationError.notebookNotFound(id)
            case .sourceNotInNotebook(let ids): throw ReportGenerationError.sourceNotInNotebook(ids)
            }
        }
        return ReportNotebook(
            sources: sources,
            documents: try await Self.subjectDocuments(notebookID: sources.notebookID, storage: storage)
        )
    }

    /// The Docs a feedback report can be about: the notebook's current
    /// Markdown Docs and Google Docs, newest first. Not its audio overviews
    /// (their body is a recipe), Sites, animations, archived or hidden Docs,
    /// or a team Doc's private draft.
    static func subjectDocuments(notebookID: String, storage: StorageService) async throws -> [ReportNotebook.Document] {
        var documents: [ReportNotebook.Document] = []
        for artifact in try await storage.loadArtifacts(notebookID: notebookID)
        where artifact.section == .docs && !artifact.isArchived && !artifact.isHidden
            && !TeamContentIdentity.isDraftArtifactID(artifact.id) {
            if artifact.kind == .audioOverview { continue }
            // An overview an older build saved back without its kind still
            // has its script source.
            if artifact.kind == nil, !artifact.isLinked,
               try await storage.loadSourceWithoutContent(GeneratedAudioOverview.carrierSourceID(artifactID: artifact.id)) != nil {
                continue
            }
            documents.append(.init(id: artifact.id, title: artifact.title))
        }
        return documents
    }

    /// The text of the Doc a feedback report is about, whole.
    func loadSubjectDocument(_ rawID: String, in notebook: ReportNotebook) async throws -> ReportSubjectDocument {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = notebook.documents.first(where: { $0.id == id }) else {
            throw ReportGenerationError.subjectNotInNotebook(id)
        }
        let snapshot = try await storage.artifactMarkdown(id)
        let text = snapshot.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReportGenerationError.subjectHasNoText(document.title) }
        return ReportSubjectDocument(id: id, title: snapshot.artifact.title, text: text)
    }

    // MARK: Plan

    /// Fits the notebook to the route and prices the writing. A feedback
    /// report's document is read whole, first among the sources when it is
    /// one of them; the rest fit around it. Options still missing their
    /// instruction or document are planned as they stand, so the sheet can
    /// price them while the learner types; `run` refuses them
    /// (`ReportOptions.gap`). Throws when the document named is not the
    /// notebook's or has no text, or when even every source read from its
    /// ideas or condensed to the least still worth reading cannot fit the
    /// window.
    static func plan(
        _ notebook: ReportNotebook,
        request: ReportRequest,
        subjectDocument: ReportSubjectDocument? = nil,
        route: NotebookWritingRoute,
        system: String = AITask.reportWriting.effectivePrompt ?? Prompts.reportWriter
    ) throws -> ReportPlan {
        let options = request.options
        var candidates = notebook.sources.candidates
        var subjectSourceID: String?
        var document: ReportSubjectDocument?
        if let subject = options.effectiveSubject {
            switch subject.kind {
            case .source:
                guard let index = candidates.firstIndex(where: { $0.source.id == subject.id }) else {
                    if let skipped = notebook.sources.skipped.first(where: { $0.sourceID == subject.id }) {
                        throw ReportGenerationError.subjectSetAside(title: skipped.title, reason: skipped.reason)
                    }
                    throw ReportGenerationError.subjectNotInNotebook(subject.id)
                }
                candidates.insert(candidates.remove(at: index), at: 0)
                subjectSourceID = subject.id
            case .doc:
                guard let subjectDocument, subjectDocument.id == subject.id else {
                    throw ReportGenerationError.subjectRequired
                }
                document = subjectDocument
            }
        }
        guard !candidates.isEmpty || document != nil else {
            throw ReportGenerationError.noSources(notebook.title)
        }

        // The turn with every source's text left out (and the document's,
        // which is counted whole below): what the request carries before
        // any source is read.
        let skeleton = writerTurn(
            notebookTitle: notebook.title,
            instructions: notebook.sources.instructions,
            options: options,
            subjectDocument: document.map { ReportSubjectDocument(id: $0.id, title: $0.title, text: "") },
            bodies: candidates.enumerated().map { offset, candidate in
                (offset + 1, candidate, .whole, "", candidate.source.id == subjectSourceID)
            }
        )
        var fixed = system.count + skeleton.count + requestOverheadCharacters
            + candidates.count * headerSlackCharacters
        // What is read whole whatever the window: the document the feedback
        // is about, a Doc or a source.
        if let document { fixed += document.text.count }
        if let subjectSourceID, let subject = candidates.first(where: { $0.source.id == subjectSourceID }) {
            fixed += subject.text.count
        }
        if let budget = route.writerInputBudget, fixed > budget, let subject = options.effectiveSubject {
            throw ReportGenerationError.subjectTooLong(model: route.modelLabel, title: document?.title ?? subject.title)
        }

        let flexible = candidates.filter { $0.source.id != subjectSourceID }
        let choices: [String: NotebookSourceBudget.Choice]
        do {
            choices = try NotebookSourceBudget.choose(
                sources: flexible.map {
                    NotebookSourceBudget.Length(id: $0.source.id, whole: $0.text.count, ideas: $0.ideas?.count)
                },
                fixedCharacters: fixed,
                budget: route.writerInputBudget,
                model: route.modelLabel
            )
        } catch let refusal as NotebookSourceBudget.DoesNotFit {
            throw ReportGenerationError.doesNotFit(model: refusal.model, sourceCount: refusal.sourceCount)
        }

        var sources: [ReportPlan.Source] = []
        for (offset, candidate) in candidates.enumerated() {
            let isSubject = candidate.source.id == subjectSourceID
            let choice = isSubject
                ? NotebookSourceBudget.Choice(readAs: .whole, targetCharacters: nil)
                : choices[candidate.source.id] ?? NotebookSourceBudget.Choice(readAs: .whole, targetCharacters: nil)
            let parts = choice.readAs == .condensed
                ? try condensingParts(
                    of: candidate,
                    targetCharacters: choice.targetCharacters ?? NotebookSourceBudget.minimumCondensedCharacters,
                    route: route
                )
                : []
            sources.append(.init(
                number: offset + 1,
                candidate: candidate,
                readAs: choice.readAs,
                condensedTargetCharacters: choice.readAs == .condensed ? choice.targetCharacters : nil,
                parts: parts,
                isSubject: isSubject
            ))
        }

        // The writer's request as it will go, with each condensed account at
        // its target length; `fixed` already holds the whole-read subject.
        let writerInputCharacters = fixed + sources.reduce(0) { total, source in
            guard !source.isSubject else { return total }
            switch source.readAs {
            case .whole: return total + source.candidate.text.count
            case .ideas: return total + (source.candidate.ideas?.count ?? 0)
            case .condensed: return total + (source.condensedTargetCharacters ?? 0)
            }
        }
        return ReportPlan(
            request: request,
            notebookTitle: notebook.title,
            instructions: notebook.sources.instructions,
            skipped: notebook.sources.skipped,
            subjectDocument: document,
            route: route,
            system: system,
            sources: sources,
            writingCost: cost(
                writerInputCharacters: writerInputCharacters,
                format: options.format,
                parts: sources.flatMap(\.parts),
                route: route
            )
        )
    }

    /// The writer's turn for these bodies: each a marker number, the source,
    /// how it is read, its text, and whether it is the feedback's document.
    static func writerTurn(
        notebookTitle: String,
        instructions: String?,
        options: ReportOptions,
        subjectDocument: ReportSubjectDocument?,
        bodies: [(Int, NotebookSourceSet.Candidate, NotebookSourceReadAs, String, Bool)]
    ) -> String {
        ReportWriterTurn.userMessage(
            notebookTitle: notebookTitle,
            instructions: instructions,
            options: options,
            subjectDocument: subjectDocument,
            sources: bodies.map { number, candidate, readAs, body, isSubject in
                ReportTurnSource(
                    number: number,
                    title: candidate.source.title,
                    kind: NotebookSourceKind.label(candidate.source.sourceType),
                    author: candidate.source.displayAuthor,
                    venue: candidate.source.journal,
                    year: candidate.source.publishedYear,
                    readAs: readAs,
                    isSubject: isSubject,
                    text: body
                )
            }
        )
    }

    /// A source's condensing calls (`NotebookSourceCondensing.slices`), sized
    /// for the report's condenser. Never a sample.
    static func condensingParts(
        of candidate: NotebookSourceSet.Candidate,
        targetCharacters: Int,
        route: NotebookWritingRoute
    ) throws -> [ReportCondensePart] {
        let slices: [NotebookSourceCondensing.Slice]
        do {
            slices = try NotebookSourceCondensing.slices(
                of: candidate.text,
                targetCharacters: targetCharacters,
                condenserInputBudget: route.condenserInputBudget,
                promptCharacters: Prompts.reportCondenser.count
            )
        } catch is NotebookSourceCondensing.WindowTooSmall {
            throw ReportGenerationError.windowTooSmall(model: route.modelLabel)
        }
        return slices.map { slice in
            ReportCondensePart(
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

    /// The writing's price: the writer's request, and each condensing call.
    static func cost(
        writerInputCharacters: Int,
        format: ReportFormat,
        parts: [ReportCondensePart],
        route: NotebookWritingRoute
    ) -> NotebookWritingCost {
        let perToken = AIService.approxCharsPerToken
        // A written word runs to about 1.4 tokens; the report's Markdown, its
        // markers and the JSON around it add a little more.
        func reportTokens(words: Int) -> Int { Int(Double(words) * 1.6) + 300 }
        func proseTokens(words: Int) -> Int { Int(Double(words) * 1.4) + 200 }

        var inputTokens = writerInputCharacters / perToken
        var expected = reportTokens(words: format.wordRange.upperBound)
        var maximum = route.outputCeiling(requested: AIService.reportWriterMaxTokens)
        var expectedUSD = route.usd(inputTokens: inputTokens, outputTokens: expected)
        var maximumUSD = route.usd(inputTokens: inputTokens, outputTokens: maximum)
        for part in parts {
            let input = (Prompts.reportCondenser.count + part.userMessage.count + requestOverheadCharacters) / perToken
            let partExpected = proseTokens(words: part.targetWords)
            let partMaximum = route.outputCeiling(requested: part.maxTokens)
            inputTokens += input
            expected += partExpected
            maximum += partMaximum
            expectedUSD = expectedUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: partExpected).map { total + $0 } }
            maximumUSD = maximumUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: partMaximum).map { total + $0 } }
        }
        return NotebookWritingCost(
            requestCount: 1 + parts.count,
            inputTokens: inputTokens,
            expectedOutputTokens: expected,
            maximumOutputTokens: maximum,
            expectedUSD: expectedUSD,
            maximumUSD: maximumUSD
        )
    }

    // MARK: Run

    /// Condenses what the plan condenses, writes the report, turns its
    /// markers into citations and saves the Doc under `artifactID` — reserved
    /// by the caller, so an MCP answer and a pending row can name the Doc
    /// before it exists. Checks for cancellation before it saves, so a
    /// stopped run leaves nothing behind.
    func run(
        _ plan: ReportPlan,
        artifactID: String = UUID().uuidString.lowercased(),
        onStage: @escaping @Sendable (ReportStage) async -> Void = { _ in }
    ) async throws -> ReportResult {
        let workflowID = UUID().uuidString
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await runStages(plan, artifactID: artifactID, onStage: onStage)
            }
        }
    }

    private func runStages(
        _ plan: ReportPlan,
        artifactID: String,
        onStage: @escaping @Sendable (ReportStage) async -> Void
    ) async throws -> ReportResult {
        switch plan.options.gap {
        case .instruction: throw ReportGenerationError.instructionRequired
        case .subject: throw ReportGenerationError.subjectRequired
        case nil: break
        }
        await onStage(.reading(sourceCount: plan.sources.count))
        let accounts = try await condense(plan, onStage: onStage)
        try Task.checkCancellation()

        let user = Self.writerTurn(
            notebookTitle: plan.notebookTitle,
            instructions: plan.instructions,
            options: plan.options,
            subjectDocument: plan.subjectDocument,
            bodies: plan.sources.map { source in
                let body: String
                switch source.readAs {
                case .whole: body = source.candidate.text
                case .ideas: body = source.candidate.ideas ?? ""
                case .condensed: body = accounts[source.candidate.source.id] ?? ""
                }
                return (source.number, source.candidate, source.readAs, body, source.isSubject)
            }
        )
        // The one-shot path trims a request that overflows the window, which
        // would cut the sources silently. The plan sized the turn to fit; a
        // condensed account that came back longer than asked is the one way
        // it can still overflow, and that is refused, not cut.
        if plan.route.writerInputBudget != nil {
            let budgeted = AIService.budgetedOneShotRequest(
                provider: plan.route.provider,
                model: plan.route.model,
                system: plan.system,
                user: user,
                requestedMaxTokens: AIService.reportWriterMaxTokens
            )
            guard budgeted.system == plan.system, budgeted.user == user else {
                throw ReportGenerationError.condensedTooLong(model: plan.route.modelLabel)
            }
        }

        await onStage(.writing(plan.options.format))
        let draft = try await backend.write(
            system: plan.system,
            user: user,
            notebookTitle: plan.notebookTitle,
            notebookID: plan.request.notebookID,
            route: plan.route
        )
        // A cancelled run that the provider still answered must not land a
        // report the learner has already given up on.
        try Task.checkCancellation()
        guard draft.isUsable else { throw ReportGenerationError.emptyReport }

        await onStage(.saving)
        let title = Self.title(of: draft, plan: plan)
        let composed = ReportCitations.compose(
            written: Self.body(of: draft, title: title),
            recipe: plan.recipe,
            sources: plan.citationSources
        )
        // The learner's take, when they wrote one, opens the report in their
        // words (`ReportTake`); the citations are grounded before it goes on,
        // so nothing they wrote is read as a source marker.
        let snapshot = try await storage.createArtifact(
            title: title,
            homeNotebookID: plan.request.notebookID,
            linkedNotebookIDs: [plan.request.notebookID],
            markdown: ReportTake.prefixed(composed.markdown, take: plan.options.trimmedTake),
            artifactID: artifactID,
            sourceIDs: plan.sources.map(\.candidate.source.id)
        )
        return ReportResult(
            artifact: snapshot.artifact,
            recipe: plan.recipe,
            citedSourceIDs: composed.citedSourceIDs,
            unresolvedMarkers: composed.unresolvedMarkers
        )
    }

    /// Every condensed source's account, by source id: its parts condensed a
    /// few at a time and joined in order.
    private func condense(
        _ plan: ReportPlan,
        onStage: @escaping @Sendable (ReportStage) async -> Void
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

    /// The report's title: the writer's, or the format and the notebook's
    /// (for feedback, the document's) when the writer gave none.
    static func title(of draft: ReportDraft, plan: ReportPlan) -> String {
        let written = draft.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        if !written.isEmpty { return written }
        if plan.options.format == .documentFeedback, let subject = plan.recipe.subjectTitle {
            return "Feedback on \(subject)"
        }
        return "\(plan.options.format.label): \(plan.notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The written Markdown without a first `# ` heading that only repeats
    /// the title the Doc keeps apart.
    static func body(of draft: ReportDraft, title: String) -> String {
        let text = draft.markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let end = text.firstIndex(of: "\n") ?? text.endIndex
        let first = text[..<end]
        guard first.hasPrefix("# ") else { return text }
        func words(_ line: some StringProtocol) -> String {
            line.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard words(first.dropFirst(2)) == words(title) else { return text }
        return String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
