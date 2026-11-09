import CryptoKit
import Foundation

// The walkthrough writer's platform-neutral half: what the writer and the
// drawer are told, how their answers become a checked record, and the run
// that ties them together. The Mac's `PaperWalkthroughGeneratorService` reads
// the text and figure index from its store and calls `run`; the phone's
// `MobileWalkthroughGenerator` reads the synced text and figures and calls the
// same `run`, so a walk written on either device is written the same way and
// held to the same checks (walkthrough-design.md, "the deck on the phone").

/// What a walkthrough walks, and what its steps may point at. The one place
/// that decides it (product owner, 2026-09-19: "it must also be possible to generate
/// walkthroughs for books (or chapters thereof) and articles"): the writer's
/// turn, the validator, the Reader's affordances and the MCP tools all ask
/// here rather than testing a source type of their own.
///
/// A paper and a chapter split from a PDF are shown as pages, so a step may
/// outline a figure the figure index lists or mark a passage found on the
/// page. An article and an EPUB chapter are shown as text or a web page: no
/// figure index, nothing to outline, so every step anchors to a passage the
/// Reader scrolls to and flashes the way a citation is shown.
enum PaperWalkthroughSubject: String, Equatable, Sendable {
    case paper
    case chapter
    case article
    /// A YouTube video (2026-09-29): its steps point at moments of the talk
    /// (`PaperWalkthroughAnchor.seconds`), and the Reader seeks the player
    /// there while the card is read. An assistant writes it with
    /// `save_walkthrough`; ForeverLM's own writer does not walk videos yet.
    case video

    /// The word the panel, menus and tool results use for the source.
    var noun: String {
        switch self {
        case .paper: return "paper"
        case .chapter: return "chapter"
        case .article: return "article"
        case .video: return "video"
        }
    }

    /// Whether ForeverLM's own writer (Write Walkthrough, `generate_walkthrough`)
    /// writes this subject's walk. A video's is saved by an assistant.
    var writerWrites: Bool { self != .video }

    /// Whether this subject's steps may point at a moment of its timeline.
    var allowsMomentAnchors: Bool { self == .video }

    /// The nouns the app's writer walks, as one phrase, for a refusal that
    /// names what qualifies.
    static let qualifyingPhrase = "a paper, a book chapter or an article"
    /// Every subject a walkthrough can be saved on.
    static let savableQualifyingPhrase = "a paper, a book chapter, an article or a video"
}

/// What the writer is told the source is: its kind, whether its steps may
/// outline figures, and the bibliography it has. Each app builds one from
/// its own record of the source (a `StudioArticle` on the Mac, a
/// `MobileCloudSource` on the phone).
struct PaperWalkthroughSourceSummary: Equatable, Sendable {
    var id: String
    var subject: PaperWalkthroughSubject?
    var allowsFigureAnchors: Bool
    var title: String
    /// The book a chapter belongs to.
    var book: String?
    /// The site an article is from.
    var domain: String?
    var author: String?
    var journal: String?
    var publishedYear: String?
    /// The source type's raw value, for usage attribution.
    var sourceType: String
}

enum PaperWalkthroughGenerationError: LocalizedError, Equatable {
    case sourceNotFound(String)
    case unsupportedSource(String)
    case noText(String)
    case noModelConfigured
    case emptyDraft
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let id):
            return "No source with id \(id) is in the library."
        case .unsupportedSource(let title):
            return "A walkthrough is written about \(PaperWalkthroughSubject.qualifyingPhrase) whose text has been read; \"\(title)\" is not one yet."
        case .noText(let title):
            return "\"\(title)\" has no text to walk through yet."
        case .noModelConfigured:
            return "No model is configured for Walkthrough Writing. Sign in and check your OpenRouter key and plan in Settings."
        case .emptyDraft:
            return "The writer returned no steps."
        case .invalid(let message):
            return message
        }
    }
}

/// Where a run is, for the toolbar's spinner and the panel's status line.
enum PaperWalkthroughGenerationStage: Equatable, Sendable {
    case reading
    /// The first writing pass: the source's argument as claims (2026-09-23).
    case mapping
    case writing
    case drawingPicture(index: Int, count: Int)
    case drawingAnimation(index: Int, count: Int)

    var label: String {
        switch self {
        case .reading: return "Reading the text…"
        case .mapping: return "Setting out the argument…"
        case .writing: return "Writing the walkthrough…"
        case .drawingPicture(let index, let count): return "Drawing picture \(index) of \(count)…"
        case .drawingAnimation(let index, let count): return "Drawing animation \(index) of \(count)…"
        }
    }
}

/// The first writing pass (2026-09-23, from the merged lesson): the source's
/// argument, before any card is written. Short, cheap and easy to check, and
/// the reason the walk teaches claims rather than touring the figures one by
/// one. Since 2026-09-29 the claims meet the figures in their printed order
/// unless the argument cannot be taught that way (`Prompts.walkthroughArgumentMapper`).
/// Decoded leniently: a list where a string was asked for is read as one
/// text, a missing field as empty.
struct PaperWalkthroughArgumentMap: Codable, Equatable, Sendable {
    struct Claim: Codable, Equatable, Sendable {
        var title: String
        var claim: String
        /// The figures and panels that carry the claim, as printed ("Figure 2a").
        var evidence: [String]

        init(title: String, claim: String, evidence: [String]) {
            self.title = title
            self.claim = claim
            self.evidence = evidence
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = PaperWalkthroughArgumentMap.text(in: container, forKey: .title) ?? ""
            claim = PaperWalkthroughArgumentMap.text(in: container, forKey: .claim) ?? ""
            evidence = PaperWalkthroughArgumentMap.strings(in: container, forKey: .evidence)
        }
    }

    var title: String
    /// The question the source asks, in a sentence.
    var question: String
    var claims: [Claim]
    /// Terms a newcomer needs, which the writer defines as Say more chips.
    var prerequisites: [String]

    init(title: String, question: String, claims: [Claim], prerequisites: [String]) {
        self.title = title
        self.question = question
        self.claims = claims
        self.prerequisites = prerequisites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = Self.text(in: container, forKey: .title) ?? ""
        question = Self.text(in: container, forKey: .question) ?? ""
        claims = (try? container.decodeIfPresent([Claim].self, forKey: .claims)) ?? []
        prerequisites = Self.strings(in: container, forKey: .prerequisites)
    }

    /// The map as the writer reads it.
    var promptLines: [String] {
        var lines = ["Title: \(title)", "The text's question: \(question)", "Claims, in teaching order:"]
        for (index, claim) in claims.enumerated() {
            var line = "\(index + 1). \(claim.title) — \(claim.claim)"
            if !claim.evidence.isEmpty { line += " [evidence: \(claim.evidence.joined(separator: ", "))]" }
            lines.append(line)
        }
        if !prerequisites.isEmpty {
            lines.append("Terms a newcomer needs: \(prerequisites.joined(separator: ", "))")
        }
        return lines
    }

    /// A string field given as a string, a number, or a list of strings (read
    /// as one text); nil when it is none of those or empty.
    static func text<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> String? {
        let value: String?
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            value = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            value = String(number)
        } else if let parts = try? container.decodeIfPresent([String].self, forKey: key) {
            value = parts.joined(separator: " ")
        } else {
            value = nil
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// A list field given as a list or as one string; empty entries dropped.
    static func strings<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [String] {
        let values: [String]
        if let list = try? container.decodeIfPresent([String].self, forKey: key) {
            values = list
        } else if let one = try? container.decodeIfPresent(String.self, forKey: key) {
            values = [one]
        } else {
            values = []
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct PaperWalkthroughGenerationResult: Equatable, Sendable {
    var walkthrough: PaperWalkthrough
    var warnings: [String]
    var replacedExisting: Bool
    /// Steps whose animation could not be drawn, by step title, with the reason.
    var animationFailures: [String]
}

/// What a run is told and how it runs, the same on both apps.
enum PaperWalkthroughWriting {
    /// Characters of source text one writing call may carry — the explainer's
    /// budget, for the same reason: a long paper is cut, not refused, and the
    /// writer is told where the text ends.
    static let sourceCharacterBudget = ExplainerScript.sourceCharacterBudget

    /// How many briefs get drawn in one run. The validator allows more on an
    /// assistant-authored walkthrough; the app's own run stays bounded.
    static let maximumAnimationsDrawn = 4

    /// How many pictures get drawn in one run. Steps without a picture show
    /// the one before them in their chapter, so a walk needs a new picture
    /// only where its point moves on; the rest of the briefs wait.
    static let maximumPicturesDrawn = 10

    /// The writer's settings, one place for both apps.
    static let writerMaxTokens = 14_000
    static let mapperMaxTokens = 3_000
    static let writerTemperature = 0.4
    static let drawerMaxTokens = 10_000
    static let drawerTemperature = 0.5

    /// The walk written, checked and saved: the argument set out first (a
    /// pass that may fail without failing the walk — the writer then sets
    /// the argument out for itself), the writer's draft validated against
    /// the text and figures, the steps saved before anything is drawn, then
    /// up to `maximumPicturesDrawn` pictures and `maximumAnimationsDrawn`
    /// animations, saved one by one, so a run stopped halfway leaves a
    /// usable walk. `drawsAnimations` covers both: off, nothing is drawn and
    /// the briefs wait. `illustrate` draws one picture brief and returns the
    /// drawn image's id; nil where this device cannot draw pictures (the
    /// phone), and the briefs wait there too. `text` is the source's
    /// canonical text, trimmed — the text the record's SHA is taken of, so
    /// the record is shown only while the source still carries it.
    static func run(
        summary: PaperWalkthroughSourceSummary,
        text: String,
        figures: [PaperWalkthroughFigureReference],
        drawsAnimations: Bool,
        map: @Sendable (_ text: String, _ truncated: Bool) async throws -> PaperWalkthroughArgumentMap,
        write: @Sendable (_ text: String, _ truncated: Bool, _ argument: PaperWalkthroughArgumentMap?) async throws -> PaperWalkthroughDraft,
        draw: @Sendable (_ step: PaperWalkthroughStep, _ figure: PaperWalkthroughFigureReference?, _ excerpt: String?) async throws -> String,
        illustrate: (@Sendable (_ step: PaperWalkthroughStep) async throws -> String)? = nil,
        save: @Sendable (PaperWalkthrough) async throws -> Void,
        onStage: (@Sendable (PaperWalkthroughGenerationStage) -> Void)? = nil,
        onStepsSaved: (@Sendable (PaperWalkthrough) -> Void)? = nil
    ) async throws -> (walkthrough: PaperWalkthrough, warnings: [String], animationFailures: [String]) {
        let sourceSHA256 = sha256(text)
        let allowsFigureAnchors = summary.allowsFigureAnchors
        let input = Self.budgeted(text)
        var warnings: [String] = []

        onStage?(.mapping)
        var argument: PaperWalkthroughArgumentMap?
        do {
            let mapped = try await map(input.text, input.truncated)
            argument = mapped.claims.isEmpty ? nil : mapped
            if mapped.claims.isEmpty { warnings.append("The argument pass named no claims; the writer set the argument out for itself.") }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("The argument pass failed (\(error.localizedDescription)); the writer set the argument out for itself.")
        }
        try Task.checkCancellation()

        onStage?(.writing)
        var draft = try await write(input.text, input.truncated, argument)
        try Task.checkCancellation()
        guard !draft.steps.isEmpty else { throw PaperWalkthroughGenerationError.emptyDraft }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.title = argument?.title.isEmpty == false ? (argument?.title ?? summary.title) : summary.title
        }

        let outcome: PaperWalkthroughValidation.Outcome
        do {
            outcome = try PaperWalkthroughValidation.walkthrough(
                title: draft.title,
                steps: PaperWalkthroughValidation.steps(from: draft),
                chapters: PaperWalkthroughValidation.chapterPlans(from: draft),
                sourceID: summary.id,
                sourceSHA256: sourceSHA256,
                figures: figures,
                allowsFigureAnchors: allowsFigureAnchors,
                text: text,
                author: .app
            )
        } catch {
            throw PaperWalkthroughGenerationError.invalid(error.localizedDescription)
        }
        warnings.append(contentsOf: outcome.warnings)
        if allowsFigureAnchors, figures.isEmpty {
            warnings.append("The figure index could not be read from the PDF, so no step outlines a figure.")
        }

        var walkthrough = outcome.walkthrough
        try await save(walkthrough)
        onStepsSaved?(walkthrough)

        if drawsAnimations, let illustrate {
            let drawn = try await drawPictures(in: &walkthrough, illustrate: illustrate, save: save, onStage: onStage, onStepsSaved: onStepsSaved)
            warnings.append(contentsOf: drawn)
        }
        let waitingPictures = walkthrough.stepsAwaitingPicture.count
        if waitingPictures > 0 {
            warnings.append("\(waitingPictures) picture brief\(waitingPictures == 1 ? " is" : "s are") not drawn yet; \(waitingPictures == 1 ? "its step shows" : "those steps show") the picture before \(waitingPictures == 1 ? "it" : "them") in the chapter meanwhile.")
        }

        var animationFailures: [String] = []
        if drawsAnimations {
            let waiting = Array(walkthrough.stepsAwaitingAnimation.prefix(maximumAnimationsDrawn))
            for (offset, step) in waiting.enumerated() {
                try Task.checkCancellation()
                onStage?(.drawingAnimation(index: offset + 1, count: waiting.count))
                let figure = step.anchor?.figureLabel.flatMap {
                    PaperWalkthroughValidation.figure(labelled: $0, in: figures)
                }
                let excerpt = sourceExcerpt(for: step, in: text)
                do {
                    let html = try await draw(step, figure, excerpt)
                    try Task.checkCancellation()
                    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        animationFailures.append("\(step.title): the drawer returned nothing.")
                        continue
                    }
                    guard trimmed.count <= PaperWalkthroughValidation.maximumAnimationCharacters else {
                        animationFailures.append("\(step.title): the animation is too large (\(trimmed.count) characters).")
                        continue
                    }
                    guard let index = walkthrough.steps.firstIndex(where: { $0.id == step.id }) else { continue }
                    walkthrough.steps[index].animationHTML = trimmed
                    try await save(walkthrough)
                    onStepsSaved?(walkthrough)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    animationFailures.append("\(step.title): \(error.localizedDescription)")
                }
            }
        }
        return (walkthrough, warnings, animationFailures)
    }

    /// Draws the waiting picture briefs, up to `maximumPicturesDrawn`, and
    /// saves the walk after each so a stopped run keeps what it drew. Steps
    /// whose briefs read the same share one drawing. Returns a line per
    /// picture that could not be drawn.
    static func drawPictures(
        in walkthrough: inout PaperWalkthrough,
        illustrate: @Sendable (_ step: PaperWalkthroughStep) async throws -> String,
        save: @Sendable (PaperWalkthrough) async throws -> Void,
        onStage: (@Sendable (PaperWalkthroughGenerationStage) -> Void)?,
        onStepsSaved: (@Sendable (PaperWalkthrough) -> Void)?
    ) async throws -> [String] {
        var failures: [String] = []
        var drawnByBrief: [String: String] = [:]
        let waiting = walkthrough.stepsAwaitingPicture
        var briefs: [String] = []
        for step in waiting {
            guard let brief = step.picture?.brief else { continue }
            let key = normalizedBrief(brief)
            if !briefs.contains(key) { briefs.append(key) }
        }
        let count = min(briefs.count, maximumPicturesDrawn)
        var drawnCount = 0
        for step in waiting {
            try Task.checkCancellation()
            guard let brief = step.picture?.brief,
                  let index = walkthrough.steps.firstIndex(where: { $0.id == step.id }) else { continue }
            let key = normalizedBrief(brief)
            let imageID: String
            if let shared = drawnByBrief[key] {
                imageID = shared
            } else {
                guard drawnCount < maximumPicturesDrawn else { continue }
                drawnCount += 1
                onStage?(.drawingPicture(index: drawnCount, count: count))
                do {
                    imageID = try await illustrate(step)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("The picture for \(step.title) could not be drawn: \(error.localizedDescription)")
                    continue
                }
                try Task.checkCancellation()
                drawnByBrief[key] = imageID
            }
            walkthrough.steps[index].picture?.imageID = imageID
            try await save(walkthrough)
            onStepsSaved?(walkthrough)
        }
        return failures
    }

    private static func normalizedBrief(_ brief: String) -> String {
        brief.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What the picture maker is asked for one step: the brief, what the
    /// step's cards say, and the house style — a teaching diagram, not an
    /// illustration for its own sake. The prompt is stored with the picture
    /// (`GeneratedImageStore`), so what made it can always be read back.
    static func picturePrompt(summary: PaperWalkthroughSourceSummary, step: PaperWalkthroughStep) -> String {
        var lines: [String] = []
        let noun = summary.subject?.noun ?? "source"
        lines.append("An explanatory picture for one card of a guided walk through the \(noun) \"\(summary.title)\".")
        lines.append("The card's point: \(clipped(step.pointBeats.map(\.text).joined(separator: " "), to: 900))")
        lines.append("What the picture must show: \(step.picture?.brief ?? step.title)")
        lines.append("Style: a clear scientific diagram on a plain white background, flat colours, clean outlines. Label only what the brief names, in a few short words each, spelled exactly; no titles, captions, paragraphs or equations. Nothing decorative, no scenery, no people unless the brief asks for them. Invent no data: no plotted values, axes with numbers or measurements the brief does not give.")
        return lines.joined(separator: "\n")
    }

    /// The SHA-256 of `text`, lowercase hex: what a record's `sourceSHA256`
    /// holds (`PaperContentPreparationService.sha256` on the Mac, the same
    /// digest).
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The text the writer sees: whole when it fits, else the opening budget
    /// with a flag so the prompt can say the end is missing.
    static func budgeted(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > sourceCharacterBudget else { return (text, false) }
        return (String(text.prefix(sourceCharacterBudget)), true)
    }

    /// The words a figure's row is read for: its own caption, or — for
    /// Nature's "See next page for caption" stub — the first later row of
    /// the same label that carries the words (the Mac's
    /// `PaperWalkthroughGeneratorService.displayCaption`, over any row type).
    static func displayCaption<Figure>(
        for figure: Figure,
        in figures: [Figure],
        label: (Figure) -> String,
        pageIndex: (Figure) -> Int,
        caption: (Figure) -> String
    ) -> String {
        guard PaperFigureCaptionTitle.isContinuedCaption(caption(figure)) else { return caption(figure) }
        let key = PaperWalkthroughValidation.canonicalLabel(label(figure))
        let continuation = figures
            .filter {
                pageIndex($0) > pageIndex(figure)
                    && PaperWalkthroughValidation.canonicalLabel(label($0)) == key
                    && !PaperFigureCaptionTitle.isContinuedCaption(caption($0))
            }
            .min(by: { pageIndex($0) < pageIndex($1) })
        return continuation.map(caption) ?? caption(figure)
    }

    /// Of several figures under one label — a caption continued onto the
    /// next page is a second row — the earliest page's, which is the figure.
    static func firstPerLabel<Figure>(_ figures: [Figure], label: (Figure) -> String, pageIndex: (Figure) -> Int) -> [Figure] {
        var seen: Set<String> = []
        var chosen: [Figure] = []
        for figure in figures.sorted(by: { pageIndex($0) < pageIndex($1) }) {
            let key = PaperWalkthroughValidation.canonicalLabel(label(figure))
            guard seen.insert(key).inserted else { continue }
            chosen.append(figure)
        }
        return chosen
    }

    /// A figure's stored vision analysis as prose the drawer can read: the
    /// summary, what is visible in it, and each panel's reading. Nil when the
    /// analysis says nothing.
    static func figureReading(_ analysis: PaperFigureAnalysis) -> String? {
        var lines: [String] = []
        let summary = analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(summary) }
        let evidence = analysis.visualEvidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !evidence.isEmpty {
            lines.append("Visible: " + evidence.joined(separator: " "))
        }
        for panel in analysis.panels {
            let explanation = panel.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !explanation.isEmpty else { continue }
            lines.append("Panel \(panel.label): \(explanation)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Characters of the source's own text one drawing turn may carry.
    static let excerptCharacterBudget = 3_000

    /// The source's own passages about a step, for the drawer: for a figure
    /// step, the paragraphs of the text that cite the figure (its caption
    /// left out, since the drawer has it already); for a passage step, the
    /// paragraph that holds the passage. Whole paragraphs in the text's
    /// order, up to `excerptCharacterBudget`; nil when nothing names the
    /// anchor. The measured values and the authors' reasoning live in these
    /// paragraphs, and a writer's three-paragraph summary drops most of them.
    static func sourceExcerpt(for step: PaperWalkthroughStep, in text: String) -> String? {
        let paragraphs = Self.paragraphs(of: text)
        var matching: [String] = []
        if let label = step.anchor?.figureLabel,
           let pattern = Self.figureMentionPattern(for: label) {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let captionPrefix = Self.figureNumberPrefix(for: label)
            for paragraph in paragraphs {
                guard let regex else { break }
                let range = NSRange(paragraph.startIndex..., in: paragraph)
                guard regex.firstMatch(in: paragraph, range: range) != nil else { continue }
                // The caption itself opens with the label; the drawer is
                // given the caption separately.
                if let captionPrefix, Self.opensWithLabel(paragraph, canonical: captionPrefix) { continue }
                matching.append(paragraph)
            }
        } else if let passage = step.anchor?.passage, !passage.isEmpty {
            let wanted = PaperWalkthroughValidation.normalized(passage)
            if let paragraph = paragraphs.first(where: { PaperWalkthroughValidation.normalized($0).contains(wanted) }) {
                matching.append(paragraph)
            }
        }
        guard !matching.isEmpty else { return nil }
        var kept: [String] = []
        var total = 0
        for paragraph in matching {
            let cost = paragraph.count + (kept.isEmpty ? 0 : 2)
            if total + cost > excerptCharacterBudget {
                if kept.isEmpty {
                    kept.append(String(paragraph.prefix(excerptCharacterBudget)) + "…")
                }
                break
            }
            kept.append(paragraph)
            total += cost
        }
        return kept.joined(separator: "\n\n")
    }

    /// The text's paragraphs: blank-line separated, or line separated when
    /// the text has no blank lines (a PDF extraction that kept one line per
    /// paragraph).
    static func paragraphs(of text: String) -> [String] {
        let blankSeparated = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if blankSeparated.count > 1 { return blankSeparated }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A pattern matching a citation of the figure in running text — "Fig. 1",
    /// "Figure 1a", "Figs. 1a and c", "Extended Data Fig. 2" — and not the
    /// figure whose number merely begins with the same digits ("Figure 12")
    /// nor, for a main figure, the extended-data or supplementary figure of
    /// the same number. Nil when the label carries no number. The same
    /// reading `PaperFigureMention` gives a figure step the authors' sentence
    /// by.
    static func figureMentionPattern(for label: String) -> String? {
        PaperFigureMention.mentionPattern(for: label)
    }

    /// The figure's label in canonical form ("figure 1", "extended data
    /// figure 2"), which `opensWithLabel` matches against a paragraph's own
    /// opening words to leave the caption out of the excerpt. Nil when the
    /// label is empty.
    static func figureNumberPrefix(for label: String) -> String? {
        let canonical = PaperWalkthroughValidation.canonicalLabel(label)
        return canonical.isEmpty ? nil : canonical
    }

    /// Whether a paragraph opens with the figure's label — "Fig. 1 |
    /// Intracellular Na…", "Figure 1. Sleep in flies" — the way a caption
    /// does (`PaperFigureMention.opensWithLabel`).
    static func opensWithLabel(_ paragraph: String, canonical: String) -> Bool {
        PaperFigureMention.opensWithLabel(paragraph, canonical: canonical)
    }

    /// The writer's turn: what the source is, what it prints, and its text.
    /// The subject decides the opening line and whether figures are offered
    /// at all: a text source is told there is nothing to outline, so every
    /// step quotes a passage the Reader can find.
    /// The mapper's turn: what the source is, what it prints, its text.
    static func mapperUserMessage(
        summary: PaperWalkthroughSourceSummary,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference]
    ) -> String {
        var lines: [String] = []
        lines.append(contentsOf: subjectLines(for: summary))
        lines.append("")
        lines.append(contentsOf: figureLinesForTurn(summary: summary, figures: figures))
        lines.append("")
        lines.append(truncated
            ? "Text (the opening only; the text continues past this and you have not seen the rest):"
            : "Text:")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    /// The writer's turn: what the source is, the argument to teach when the
    /// first pass set one out, what the source prints, its text.
    static func writerUserMessage(
        summary: PaperWalkthroughSourceSummary,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap? = nil,
        learner: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append(contentsOf: subjectLines(for: summary))
        lines.append("")
        if let learner = learnerLine(learner) {
            lines.append(learner)
            lines.append("")
        }
        if let argument, !argument.claims.isEmpty {
            lines.append("The argument to teach, one chapter per claim:")
            lines.append(contentsOf: argument.promptLines)
            lines.append("")
        }
        lines.append(contentsOf: figureLinesForTurn(summary: summary, figures: figures))
        lines.append("")
        lines.append(truncated
            ? "Text (the opening only; the text continues past this and you have not seen the rest):"
            : "Text:")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    /// The learner's own words about where they are coming from (Settings ›
    /// About you, `LearnerProfile.aboutYou` on the Mac), for the
    /// writer to pitch the walk to; nil when they have said nothing, and
    /// the writer then writes for a newcomer to the field
    /// (`Prompts.walkthroughWriter`, "Pitch it to the learner"). One line,
    /// however the learner broke it.
    static func learnerLine(_ aboutYou: String?) -> String? {
        let words = (aboutYou ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return "The learner, on where they are coming from, in their own words: \(words)"
    }

    /// The figure section of a writing turn: the list, or the note that the
    /// source prints none the Reader can outline.
    static func figureLinesForTurn(summary: PaperWalkthroughSourceSummary, figures: [PaperWalkthroughFigureReference]) -> [String] {
        var lines: [String] = []
        if !summary.allowsFigureAnchors {
            let noun = summary.subject?.noun ?? "source"
            lines.append("Figures: this \(noun) is shown as text, not as a PDF, so there is nothing for the Reader to outline. Write no step of kind \"figure\" and leave \"figure_label\" and \"panel_label\" null on every step and in every picture — a picture here is always a brief to draw — and ask no \"predict\" or \"find\" question; a step whose point is in particular words of the text carries them as a \"passage\" quoted exactly, so the Reader can scroll to them, and a step that sets up or sums up stays unanchored. Where the text describes a figure, quote the sentence that describes it.")
        } else if figures.isEmpty {
            lines.append("Figures: none could be read from the PDF, so write no step of kind \"figure\", make every picture a brief to draw, and ask no \"predict\" or \"find\" question; a step whose point is in particular words of the text quotes them as a passage instead.")
        } else {
            lines.append("Figures printed in the paper (label · page · caption · panels · the words printed inside the figure in reading order — its axis titles with their units, legend keys, condition labels — which are what to read each panel by · what an earlier look at the figure saw):")
            lines.append(contentsOf: figureLines(figures))
        }
        return lines
    }

    /// One line per figure, as the writer reads a figure it cannot see: label,
    /// page, caption, panels, the words printed inside it and what an earlier
    /// look at it saw. The explainer writer is handed the same lines
    /// (`ExplainerGeneratorService.figureLines`), so both scripts read a figure
    /// from one account of it.
    static func figureLines(_ figures: [PaperWalkthroughFigureReference]) -> [String] {
        figures.map { figure in
            var line = "- \(figure.label) · page \(figure.pageNumber) · \(Self.clipped(figure.caption, to: 600))"
            if !figure.panelLabels.isEmpty {
                line += " · panels: \(figure.panelLabels.joined(separator: ", "))"
            }
            if !figure.printedText.isEmpty {
                line += " · printed in the figure: \(Self.clipped(figure.printedText.joined(separator: "; "), to: 700))"
            }
            if let reading = figure.reading, !reading.isEmpty {
                line += " · seen: \(Self.clipped(reading, to: 900))"
            }
            return line
        }
    }

    /// The lines that say what the source is: "Paper:", "Chapter:" with its
    /// book, or "Article:", then the bibliography the source has.
    static func subjectLines(for source: PaperWalkthroughSourceSummary) -> [String] {
        var lines: [String] = []
        switch source.subject {
        case .chapter:
            lines.append("Chapter: \(source.title)")
            if let book = source.book, !book.isEmpty { lines.append("Book: \(book)") }
        case .article:
            lines.append("Article: \(source.title)")
            if let domain = source.domain, !domain.isEmpty { lines.append("Site: \(domain)") }
        case .video:
            lines.append("Video: \(source.title)")
        case .paper, nil:
            lines.append("Paper: \(source.title)")
        }
        if let author = source.author, !author.isEmpty { lines.append("Authors: \(author)") }
        if let journal = source.journal, !journal.isEmpty { lines.append("Venue: \(journal)") }
        if let year = source.publishedYear, !year.isEmpty { lines.append("Year: \(year)") }
        return lines
    }

    /// The drawer's turn: the step, the figure it is about with its caption
    /// and, when it has been looked at, its reading; the source's own
    /// passages about it; and the brief — what the learner should come away
    /// understanding — which the drawer turns into its written plan before
    /// it draws (`Prompts.walkthroughAnimator`).
    static func animatorUserMessage(
        summary: PaperWalkthroughSourceSummary,
        step: PaperWalkthroughStep,
        figure: PaperWalkthroughFigureReference?,
        excerpt: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append(subjectLines(for: summary).first ?? "Source: \(summary.title)")
        lines.append("Step: \(step.title)")
        if let figure {
            lines.append("Figure: \(step.anchor?.figureDisplayLabel ?? figure.label) — \(Self.clipped(figure.caption, to: 800))")
            if let reading = figure.reading, !reading.isEmpty {
                lines.append("")
                lines.append("What the figure shows (from looking at it):")
                lines.append(Self.clipped(reading, to: 2_000))
            }
        }
        lines.append("")
        lines.append("Step text:")
        lines.append(step.body)
        if let excerpt, !excerpt.isEmpty {
            lines.append("")
            lines.append("The source's own words about this (use its measured values; invent none):")
            lines.append(excerpt)
        }
        lines.append("")
        lines.append("Brief — what the learner should come away understanding:")
        lines.append(step.animationBrief ?? "Draw what the step text describes, in motion.")
        return lines.joined(separator: "\n")
    }

    /// The HTML document in a model's answer: the text from `<!DOCTYPE` or
    /// `<html` to the closing `</html>`, with any Markdown fence around it
    /// dropped. Nil when the answer holds no document.
    static func htmlDocument(in response: String) -> String? {
        let lowered = response.lowercased()
        let start = lowered.range(of: "<!doctype html")?.lowerBound
            ?? lowered.range(of: "<html")?.lowerBound
        guard let start else { return nil }
        let end = lowered.range(of: "</html>", options: .backwards)?.upperBound ?? response.endIndex
        guard start < end else { return nil }
        let document = String(response[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return document.isEmpty ? nil : document
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
