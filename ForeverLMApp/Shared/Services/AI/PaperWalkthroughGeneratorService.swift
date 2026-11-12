#if os(macOS)
import Foundation

struct PaperWalkthroughRequest: Equatable, Sendable {
    var sourceID: String
    /// Whether the steps the writer briefed for an animation or a picture
    /// get one drawn. Off, the steps are saved with their briefs and nothing
    /// else is spent.
    var drawsAnimations: Bool = true
}

/// What a Mac source is as a walkthrough subject (`PaperWalkthroughSubject`,
/// in `PaperWalkthroughWriting.swift`). The one place that decides it
/// (product owner, 2026-09-19): the writer's turn, the validator, the Reader's
/// affordances and the MCP tools all ask here rather than testing a source
/// type of their own.
extension PaperWalkthroughSubject {
    /// The subject a source is, or nil for a source no walkthrough is written
    /// about — a podcast, a meeting, a video off YouTube, an explainer's own
    /// page. A YouTube video is one: the Reader's player is
    /// what a moment step seeks.
    static func of(_ article: StudioArticle) -> PaperWalkthroughSubject? {
        switch article.sourceType {
        case .paper:
            return .paper
        case .book:
            return .chapter
        case .article:
            return GeneratedExplainer.isSpokenScriptURL(article.url) ? nil : .article
        case .video:
            return article.isYouTubeURL ? .video : nil
        default:
            return nil
        }
    }

    /// Whether the source's steps may outline figures: only a source read
    /// from a PDF has a figure index and a page to outline on. A paper is
    /// taken to (its index may still be empty); a chapter only when its file
    /// is a PDF rather than an EPUB's text; an article or a video never.
    static func allowsFigureAnchors(_ article: StudioArticle) -> Bool {
        switch of(article) {
        case .paper: return true
        case .chapter: return article.isPDF
        case .article, .video, nil: return false
        }
    }

    /// Whether the source's text is there to walk through. A paper waits for
    /// its ingestion to finish (its canonical text and attested metadata); a
    /// chapter, an article and a video are ready once their text — for a
    /// video, its transcript — has been read.
    static func isReady(_ article: StudioArticle) -> Bool {
        switch of(article) {
        case .paper:
            // The walk is written from the paper's canonical text and its
            // figure index; unlike Explain it never narrates, so the listenable
            // derivative — which a moved narration contract leaves stale on
            // papers whose text is fine — is not asked for.
            return article.isPaperReadyForListenPreparation
        case .chapter, .article, .video:
            return article.state == .ready
        case nil:
            return false
        }
    }

    /// The text a walk of the source is written against, checked against and
    /// fingerprinted by. A video's stored content carries its slide block
    /// once the slides are captured; its walk is of the talk, so it is held
    /// to the transcript alone and capturing slides never makes it stale.
    /// Every other source's text is its whole content.
    static func walkedText(of content: String) -> String {
        guard SlideFrameExtraction.containsSlideSection(content) else { return content }
        let transcript = YouTubeSlideContentParser.parse(content).transcriptContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? content : transcript
    }

    /// The last moment a video's walk may point at: two minutes past the
    /// transcript's last line, the tail it may still be talking over. Nil
    /// when the transcript names no times.
    static func momentLimit(ofTranscript text: String) -> Int? {
        let last = YouTubeTranscriptDisplayParser.parse(text).segments
            .compactMap { YouTubeTranscriptTime.seconds(from: $0.startTime) }
            .max()
        return last.map { Int($0) + 120 }
    }

    /// What the writer is told the source is.
    static func summary(for article: StudioArticle) -> PaperWalkthroughSourceSummary {
        PaperWalkthroughSourceSummary(
            id: article.id,
            subject: of(article),
            allowsFigureAnchors: allowsFigureAnchors(article),
            title: article.title,
            book: article.parentGroup,
            domain: article.domain,
            author: article.author,
            journal: article.journal,
            publishedYear: article.publishedYear,
            sourceType: article.sourceType.rawValue
        )
    }
}

/// The model side of the pipeline, behind a protocol so the storage side can
/// be pinned in tests with a canned draft.
protocol PaperWalkthroughModelBackend: Sendable {
    /// The first pass: the source's argument as claims in teaching order
    /// (`Prompts.walkthroughArgumentMapper`). A failure here costs the map,
    /// not the walk: the writer then sets the argument out for itself.
    func mapArgument(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference]
    ) async throws -> PaperWalkthroughArgumentMap

    /// The steps, in chapters, against `argument` when the first pass set
    /// one out.
    func write(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap?
    ) async throws -> PaperWalkthroughDraft

    /// One complete HTML document for the step, from its brief. `excerpt` is
    /// the source's own passages about the step — the paragraphs that cite
    /// the step's figure, or the one that holds its passage
    /// (`PaperWalkthroughGeneratorService.sourceExcerpt`) — so the drawer
    /// has the measured values and the reasoning, not only the writer's
    /// summary of them. Nil when the text has nothing that names the anchor.
    func drawAnimation(
        source: StudioArticle,
        step: PaperWalkthroughStep,
        figure: PaperWalkthroughFigureReference?,
        excerpt: String?
    ) async throws -> String

    /// Draws one card picture from its prompt
    /// (`PaperWalkthroughWriting.picturePrompt`) and returns the stored
    /// image's id; `title` names it in the image store.
    func drawPicture(prompt: String, title: String) async throws -> String
}

extension PaperWalkthroughModelBackend {
    /// A backend that draws no pictures leaves the briefs waiting.
    func drawPicture(prompt: String, title: String) async throws -> String {
        throw PaperWalkthroughGenerationError.invalid("This writer draws no pictures.")
    }
}

/// Writes with the learner's Walkthrough Writing and Walkthrough Animation models.
struct LivePaperWalkthroughModelBackend: PaperWalkthroughModelBackend {
    let aiService: AIService

    func mapArgument(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference]
    ) async throws -> PaperWalkthroughArgumentMap {
        guard let config = KeychainService.resolveConfig(for: .walkthroughWriting) else {
            throw PaperWalkthroughGenerationError.noModelConfigured
        }
        return try await aiService.mapWalkthroughArgument(
            source: source,
            text: text,
            truncated: truncated,
            figures: figures,
            config: config
        )
    }

    func write(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap?
    ) async throws -> PaperWalkthroughDraft {
        guard let config = KeychainService.resolveConfig(for: .walkthroughWriting) else {
            throw PaperWalkthroughGenerationError.noModelConfigured
        }
        return try await aiService.writeWalkthrough(
            source: source,
            text: text,
            truncated: truncated,
            figures: figures,
            argument: argument,
            config: config
        )
    }

    func drawAnimation(
        source: StudioArticle,
        step: PaperWalkthroughStep,
        figure: PaperWalkthroughFigureReference?,
        excerpt: String?
    ) async throws -> String {
        guard let config = KeychainService.resolveConfig(for: .walkthroughAnimation) else {
            throw PaperWalkthroughGenerationError.noModelConfigured
        }
        return try await aiService.drawWalkthroughAnimation(
            source: source,
            step: step,
            figure: figure,
            excerpt: excerpt,
            config: config
        )
    }

    /// The account's image model (Settings → Images), billed as the chat's
    /// pictures are; the picture is kept in the image store with the prompt
    /// that made it, and shown on its card.
    func drawPicture(prompt: String, title: String) async throws -> String {
        let model = await MainActor.run { MacImageGenerationSettings.model }
        let stored = try await ManagedImageGeneration.drawAndStore(
            prompt: prompt,
            title: title,
            model: model,
            shape: .landscape,
            quality: .medium,
            revising: nil,
            usageTask: "walkthrough_picture"
        )
        return stored.imageID
    }
}

/// The walkthrough pipeline: read the paper's text and its figure index, have
/// the writer turn them into steps, check every step's anchor against the
/// paper, save, then draw the animations the writer asked for one by one,
/// saving after each so a run that stops halfway leaves a usable walk.
///
/// Runs off the main actor. Usage for the run is attributed to one activity
/// id, so Settings → AI activity shows the walkthrough as one line.
struct PaperWalkthroughGeneratorService: Sendable {
    let storage: StorageService
    let backend: any PaperWalkthroughModelBackend
    let figureIndexer: PaperFigureIndexer

    static let sourceCharacterBudget = PaperWalkthroughWriting.sourceCharacterBudget
    static let maximumAnimationsDrawn = PaperWalkthroughWriting.maximumAnimationsDrawn

    init(storage: StorageService, backend: any PaperWalkthroughModelBackend, figureIndexer: PaperFigureIndexer) {
        self.storage = storage
        self.backend = backend
        self.figureIndexer = figureIndexer
    }

    func run(
        request: PaperWalkthroughRequest,
        onStage: (@Sendable (PaperWalkthroughGenerationStage) -> Void)? = nil,
        onStepsSaved: (@Sendable (PaperWalkthrough) -> Void)? = nil
    ) async throws -> PaperWalkthroughGenerationResult {
        let workflowID = UUID().uuidString
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await runStages(request: request, onStage: onStage, onStepsSaved: onStepsSaved)
            }
        }
    }

    private func runStages(
        request: PaperWalkthroughRequest,
        onStage: (@Sendable (PaperWalkthroughGenerationStage) -> Void)?,
        onStepsSaved: (@Sendable (PaperWalkthrough) -> Void)?
    ) async throws -> PaperWalkthroughGenerationResult {
        onStage?(.reading)
        let sourceID = request.sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = try await storage.loadSourceWithoutContent(sourceID) else {
            throw PaperWalkthroughGenerationError.sourceNotFound(sourceID)
        }
        guard Self.canWalkThrough(source) else {
            throw PaperWalkthroughGenerationError.unsupportedSource(source.title)
        }
        guard let text = await storage.loadSourceContent(source.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw PaperWalkthroughGenerationError.noText(source.title)
        }

        // The structural index is a read of the PDF: labels, pages, captions.
        // A paper whose PDF cannot be read right now still gets a walkthrough,
        // one whose figure steps have no anchors, which the warnings say. A
        // source shown as text has no index to read and no figure to outline;
        // its steps are anchored with passages alone.
        let allowsFigureAnchors = PaperWalkthroughSubject.allowsFigureAnchors(source)
        let figures: [PaperWalkthroughFigureReference]
        if allowsFigureAnchors {
            let pdfPath = try? await storage.paperFigureIndexTarget(sourceID: source.id)?.pdfPath
            figures = try await Self.figureReferences(sourceID: source.id, indexer: figureIndexer, pdfPath: pdfPath)
        } else {
            figures = []
        }

        let replacedExisting = try await storage.hasPaperWalkthrough(source.id)
        let storage = self.storage
        let backend = self.backend
        let summary = PaperWalkthroughSubject.summary(for: source)
        let written = try await PaperWalkthroughWriting.run(
            summary: summary,
            text: text,
            figures: figures,
            drawsAnimations: request.drawsAnimations,
            map: { text, truncated in
                try await backend.mapArgument(source: source, text: text, truncated: truncated, figures: figures)
            },
            write: { text, truncated, argument in
                try await backend.write(source: source, text: text, truncated: truncated, figures: figures, argument: argument)
            },
            draw: { step, figure, excerpt in
                try await backend.drawAnimation(source: source, step: step, figure: figure, excerpt: excerpt)
            },
            illustrate: { step in
                try await backend.drawPicture(prompt: PaperWalkthroughWriting.picturePrompt(summary: summary, step: step), title: step.title)
            },
            save: { try await storage.savePaperWalkthrough($0) },
            onStage: onStage,
            onStepsSaved: onStepsSaved
        )
        return PaperWalkthroughGenerationResult(
            walkthrough: written.walkthrough,
            warnings: written.warnings,
            replacedExisting: replacedExisting,
            animationFailures: written.animationFailures
        )
    }

    /// Whether ForeverLM's writer writes this source's walkthrough: a paper, a
    /// book chapter or an article whose text is there to walk through
    /// (`PaperWalkthroughSubject.isReady`). A video's walk is an assistant's
    /// (`save_walkthrough`); the Reader plays one saved (`canPlayWalkthrough`).
    static func canWalkThrough(_ article: StudioArticle) -> Bool {
        PaperWalkthroughSubject.isReady(article) && PaperWalkthroughSubject.of(article)?.writerWrites == true
    }

    /// Whether the Reader offers to play a walkthrough the source has: any
    /// ready subject, a video included.
    static func canPlayWalkthrough(_ article: StudioArticle) -> Bool {
        PaperWalkthroughSubject.isReady(article)
    }

    static func budgeted(_ text: String) -> (text: String, truncated: Bool) {
        PaperWalkthroughWriting.budgeted(text)
    }

    /// The paper's figures as the writer and the validator see them, from the
    /// structural index (free) plus whatever analysis some figures already have.
    static func figureReferences(
        sourceID: String,
        indexer: PaperFigureIndexer,
        pdfPath: String? = nil
    ) async throws -> [PaperWalkthroughFigureReference] {
        let records: [PaperFigureRecord]
        do {
            records = try await indexer.prepareStructure(sourceID: sourceID)
        } catch {
            return []
        }
        return Self.figureReferences(from: records, pdfPath: pdfPath)
    }

    /// The references the writer and the validator see. Panel labels come
    /// from the vision analysis where a figure has one and from the page's
    /// own text layer otherwise (`PaperFigurePanelLocator`), so the writer is
    /// told which panels a figure prints and the validator can hold it to
    /// addressing every one. Every figure on a readable PDF also carries the
    /// words its text layer prints — axis titles, legend keys, condition
    /// labels — so a figure step can read the picture out rather than
    /// gesture at it.
    static func figureReferences(
        from records: [PaperFigureRecord],
        pdfPath: String? = nil
    ) -> [PaperWalkthroughFigureReference] {
        // A caption continued onto the next page produces a second row with
        // the same label; the figure itself is the earlier one.
        let chosen = PaperWalkthroughWriting.firstPerLabel(records, label: \.figureLabel, pageIndex: \.pageIndex)
        let readings: [String: PaperFigurePanelLocator.TextLayerReading]
        if let pdfPath {
            readings = PaperFigurePanelLocator.textLayer(for: chosen, pdfPath: pdfPath)
        } else {
            readings = [:]
        }
        return chosen.map { record in
            let analysed = record.analysis?.panels.map(\.label) ?? []
            let textLayer = readings[record.id]
            return PaperWalkthroughFigureReference(
                label: record.figureLabel,
                pageNumber: record.pageNumber,
                caption: displayCaption(for: record, in: records),
                panelLabels: analysed.isEmpty ? (textLayer?.panelLabels ?? []) : analysed,
                reading: record.analysis.flatMap(Self.figureReading),
                printedText: textLayer?.printedText ?? []
            )
        }
    }

    static func figureReading(_ analysis: PaperFigureAnalysis) -> String? {
        PaperWalkthroughWriting.figureReading(analysis)
    }

    static let excerptCharacterBudget = PaperWalkthroughWriting.excerptCharacterBudget

    static func sourceExcerpt(for step: PaperWalkthroughStep, in text: String) -> String? {
        PaperWalkthroughWriting.sourceExcerpt(for: step, in: text)
    }

    static func paragraphs(of text: String) -> [String] {
        PaperWalkthroughWriting.paragraphs(of: text)
    }

    /// The words a figure's row is read for — the writer's list, the chat's
    /// anchor chip, the tutor's focus reply. Nature prints a figure that
    /// fills its page under "Extended Data Fig. 1 | See next page for
    /// caption." and the caption itself on the page after, as a second row
    /// with the same label. The figure's row keeps the stub, because that
    /// line is what the crop locator finds on the figure's page
    /// (`PaperFigureRectRefiner.captionBounds`); its words come from the
    /// first later row of the same label that carries them.
    static func displayCaption(for record: PaperFigureRecord, in figures: [PaperFigureRecord]) -> String {
        PaperWalkthroughWriting.displayCaption(
            for: record,
            in: figures,
            label: \.figureLabel,
            pageIndex: \.pageIndex,
            caption: \.caption
        )
    }

    /// `record` with its words read from the continuation row, for a surface
    /// that shows the caption rather than searching the page for it.
    static func displayRecord(for record: PaperFigureRecord, in figures: [PaperFigureRecord]) -> PaperFigureRecord {
        let caption = displayCaption(for: record, in: figures)
        guard caption != record.caption else { return record }
        return PaperFigureRecord(
            id: record.id,
            sourceID: record.sourceID,
            figureLabel: record.figureLabel,
            pageIndex: record.pageIndex,
            caption: caption,
            analysis: record.analysis
        )
    }

    /// The figure record a label names, by the tools' match first and the
    /// validator's looser one ("Figure 2a" → Figure 2) second. The Reader, the
    /// MCP payload and the panel's figure title all look figures up this way.
    static func figureRecord(labelled label: String, in figures: [PaperFigureRecord]) -> PaperFigureRecord? {
        if let exact = PaperFigureIndexer.figure(labelled: label, in: figures) { return exact }
        let references = figureReferences(from: figures)
        guard let reference = PaperWalkthroughValidation.figure(labelled: label, in: references) else { return nil }
        return figures.first { $0.figureLabel == reference.label && $0.pageNumber == reference.pageNumber }
    }

    // MARK: Turns (`PaperWalkthroughWriting`, from a Mac source)

    static func mapperUserMessage(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference]
    ) -> String {
        PaperWalkthroughWriting.mapperUserMessage(
            summary: PaperWalkthroughSubject.summary(for: source),
            text: text,
            truncated: truncated,
            figures: figures
        )
    }

    static func writerUserMessage(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap? = nil,
        learner: String? = nil
    ) -> String {
        PaperWalkthroughWriting.writerUserMessage(
            summary: PaperWalkthroughSubject.summary(for: source),
            text: text,
            truncated: truncated,
            figures: figures,
            argument: argument,
            learner: learner
        )
    }

    static func figureLines(_ figures: [PaperWalkthroughFigureReference]) -> [String] {
        PaperWalkthroughWriting.figureLines(figures)
    }

    static func subjectLines(for source: StudioArticle) -> [String] {
        PaperWalkthroughWriting.subjectLines(for: PaperWalkthroughSubject.summary(for: source))
    }

    static func animatorUserMessage(
        source: StudioArticle,
        step: PaperWalkthroughStep,
        figure: PaperWalkthroughFigureReference?,
        excerpt: String? = nil
    ) -> String {
        PaperWalkthroughWriting.animatorUserMessage(
            summary: PaperWalkthroughSubject.summary(for: source),
            step: step,
            figure: figure,
            excerpt: excerpt
        )
    }
}
#endif
