// Validation of a walkthrough the writer returned, and the figure reference it checks against.
import Foundation

// MARK: - Validation

/// One figure the paper prints, as the validator and the writer see it.
struct PaperWalkthroughFigureReference: Equatable, Sendable {
    let label: String
    let pageNumber: Int
    let caption: String
    /// Panel labels the figure's analysis found, when it has been analysed.
    let panelLabels: [String]
    /// What the figure shows, in prose, when it has been looked at: the vision
    /// analysis's summary, what is visible, and each panel's reading
    /// (`PaperWalkthroughGeneratorService.figureReading`). The animator draws
    /// from this rather than from the caption alone, so its stage mirrors the
    /// figure's axes, conditions and values. Nil until the figure is analysed.
    var reading: String? = nil
    /// The words the figure prints, read off the PDF's text layer in reading
    /// order — axis titles with their units, legend keys, condition labels,
    /// significance marks — so the writer can say what an axis is without
    /// seeing the picture (`PaperFigurePanelLocator.printedText`). Empty for
    /// a raster figure, whose text layer holds nothing there.
    var printedText: [String] = []
}

/// Turns a draft into a walkthrough the Reader can follow, dropping what it
/// could not find. Anchors are matched deterministically: a figure label
/// against the paper's figure index and a passage against its text. A step
/// whose anchor fails keeps its words and loses only the scroll target, and
/// the warnings say which, so a caller can see what the writer invented.
enum PaperWalkthroughValidation {
    /// Steps that are not questions. A figure step is one panel, so a paper
    /// with five four-panel figures needs the room.
    static let maximumSteps = 40
    /// Questions, counted apart from `maximumSteps`: the writer is asked for
    /// ten to thirty steps "not counting the questions", and one question
    /// every two or three steps and at each chapter's end. Counting them
    /// together refused a 44-step walk the prompt had asked for (the
    /// MitoSpace paper).
    static let maximumQuestions = 20
    static let maximumPassageWords = 40
    /// An animation document larger than this is refused rather than cut: a
    /// cut HTML document is a broken one.
    static let maximumAnimationCharacters = 24_000
    static let maximumAnimationsPerWalkthrough = 6

    struct Outcome: Equatable, Sendable {
        var walkthrough: PaperWalkthrough
        var warnings: [String]
    }

    /// A chapter as a writer or `save_walkthrough` names it: its title, its
    /// claim and the ids of the raw steps it groups. Validation keeps the
    /// steps that survive and drops a chapter left with none.
    struct ChapterPlan: Equatable, Sendable {
        var title: String
        var claim: String
        var stepIDs: [String]
    }

    static let maximumChapters = 10
    static let maximumMorePerStep = 3

    enum Failure: LocalizedError, Equatable {
        case noSteps
        case tooManySteps(Int)
        case tooManyQuestions(Int)
        case tooManyChapters(Int)
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .noSteps:
                return "The walkthrough has no usable steps."
            case .tooManySteps(let count):
                return "The walkthrough has \(count) steps besides its questions; at most \(PaperWalkthroughValidation.maximumSteps) are allowed."
            case .tooManyQuestions(let count):
                return "The walkthrough asks \(count) questions; at most \(PaperWalkthroughValidation.maximumQuestions) are allowed."
            case .tooManyChapters(let count):
                return "The walkthrough has \(count) chapters; at most \(PaperWalkthroughValidation.maximumChapters) are allowed."
            case .emptyTitle:
                return "The walkthrough needs a title."
            }
        }
    }

    /// Builds the record from validated steps. `steps` may come from the
    /// writer's draft or from an assistant's `save_walkthrough` call; both go
    /// through the same anchor checks.
    ///
    /// `allowsFigureAnchors` is the source's capability, decided once by
    /// `PaperWalkthroughSubject`: a source shown as a PDF may point at the
    /// figures its index lists, a source shown as text may not. A figure
    /// anchor on a passages-only source is refused with a warning that says
    /// why, whatever `figures` holds; the words stay and the step becomes an
    /// explanation.
    ///
    /// `subject` is what the walk is of. An animation walk has no page to
    /// point at, so an anchor on one of its steps is dropped with a warning;
    /// its steps show the animation by reference instead
    /// (`PaperWalkthroughStep.animation`), which any walk's step may also do.
    static func walkthrough(
        title: String,
        steps rawSteps: [PaperWalkthroughStep],
        chapters chapterPlans: [ChapterPlan]? = nil,
        sourceID: String,
        sourceSHA256: String,
        subject: PaperWalkthrough.Subject = .source,
        figures: [PaperWalkthroughFigureReference],
        allowsFigureAnchors: Bool = true,
        allowsMomentAnchors: Bool = false,
        momentLimit: Int? = nil,
        text: String,
        author: PaperWalkthrough.Author,
        generatedAt: Date = Date()
    ) throws -> Outcome {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw Failure.emptyTitle }
        let questionCount = rawSteps.filter { $0.kind == .quiz }.count
        guard rawSteps.count - questionCount <= maximumSteps else { throw Failure.tooManySteps(rawSteps.count - questionCount) }
        guard questionCount <= maximumQuestions else { throw Failure.tooManyQuestions(questionCount) }
        if let chapterPlans, chapterPlans.count > maximumChapters { throw Failure.tooManyChapters(chapterPlans.count) }

        var warnings: [String] = []
        var steps: [PaperWalkthroughStep] = []
        var animations = 0
        let normalizedText = normalized(text)

        for (index, raw) in rawSteps.enumerated() {
            let position = index + 1
            let stepTitle = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var beats = (raw.beats ?? []).compactMap { beat -> PaperWalkthroughBeat? in
                let text = beat.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let figure = beat.figureLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                let panel = beat.panelLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PaperWalkthroughBeat(
                    text: text,
                    figureLabel: figure?.isEmpty == false ? figure : nil,
                    panelLabel: panel?.isEmpty == false ? panel : nil
                )
            }
            // A step written as beats alone reads as those beats in its body
            // too, which is what the panel checks, the tutor and every
            // client that knows no beats read.
            let writtenBody = raw.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = writtenBody.isEmpty ? beats.map(\.text).joined(separator: " ") : writtenBody
            guard !stepTitle.isEmpty || !body.isEmpty else {
                warnings.append("Step \(position) had no title and no text and was dropped.")
                continue
            }
            var step = PaperWalkthroughStep(
                id: raw.id.isEmpty ? "step-\(position)" : raw.id,
                kind: raw.kind,
                title: stepTitle.isEmpty ? raw.kind.label : stepTitle,
                body: body,
                anchor: nil,
                animationHTML: nil,
                animationBrief: raw.animationBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
                quiz: nil,
                beats: beats.isEmpty ? nil : beats
            )
            if step.animationBrief?.isEmpty == true { step.animationBrief = nil }
            // Say more chips: label and text both present, at most three.
            step.more = raw.more.compactMap { more -> PaperWalkthroughMore? in
                let label = more.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = more.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !text.isEmpty else { return nil }
                return PaperWalkthroughMore(label: label, text: text, fromPaper: more.fromPaper)
            }
            if step.more.count > maximumMorePerStep {
                warnings.append("Step \(position) offers \(step.more.count) Say more chips; the first \(maximumMorePerStep) were kept.")
                step.more = Array(step.more.prefix(maximumMorePerStep))
            }
            step.cites = citations(raw.cites, stepPosition: position, walkedSourceID: sourceID, warnings: &warnings)

            // Anchor.
            if subject == .animation, let anchor = raw.anchor, !anchor.isEmpty {
                let named = anchor.figureDisplayLabel ?? anchor.passage.map { "“\($0)”" } ?? anchor.momentClock ?? "a page"
                warnings.append("Step \(position) points at \(named), but a walkthrough of an animation has no page to point at; the anchor was dropped.")
            } else if let anchor = raw.anchor, !anchor.isEmpty {
                var resolved = PaperWalkthroughAnchor()
                if let label = anchor.figureLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    if !allowsFigureAnchors {
                        warnings.append("Step \(position) names \(label), but this source is shown as text and has no figures to outline; the figure anchor was dropped. Anchor the step with a passage instead.")
                    } else if let figure = figure(labelled: label, in: figures) {
                        resolved.figureLabel = figure.label
                        resolved.pageNumber = figure.pageNumber
                        if let panel = anchor.panelLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !panel.isEmpty {
                            // A panel is kept even when the figure has not been
                            // analysed yet: the Reader falls back to the whole
                            // figure until the panel's rectangle is known.
                            resolved.panelLabel = panel
                        }
                    } else {
                        warnings.append("Step \(position) names \(label), which the paper's figure index does not have; the figure anchor was dropped.")
                    }
                }
                if let passage = anchor.passage?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty {
                    let clipped = clippedPassage(passage)
                    if normalizedText.isEmpty || normalizedText.contains(normalized(clipped)) {
                        resolved.passage = clipped
                    } else {
                        warnings.append("Step \(position) quotes a passage the paper's text does not contain; the passage anchor was dropped.")
                    }
                }
                if resolved.passage == nil, resolved.figureLabel == nil, let page = anchor.pageNumber, page > 0 {
                    resolved.pageNumber = page
                }
                // A moment of a video: kept on a video's walk while it falls
                // inside the talk; anywhere else there is no timeline to seek.
                if let seconds = anchor.seconds {
                    let clock = anchor.momentClock ?? "\(seconds)s"
                    if !allowsMomentAnchors {
                        warnings.append("Step \(position) points at \(clock), but this source has no timeline to seek; the moment was dropped.")
                    } else if seconds < 0 || (momentLimit.map { seconds > $0 } ?? false) {
                        warnings.append("Step \(position) points at \(clock), which is past the end of the talk's transcript; the moment was dropped.")
                    } else {
                        resolved.seconds = seconds
                    }
                }
                if !resolved.isEmpty { step.anchor = resolved }
            }
            // A beat's figure is checked as the step's is: one the index does
            // not have loses its pointer and keeps its words.
            for (beatIndex, beat) in beats.enumerated() {
                if let label = beat.figureLabel {
                    if allowsFigureAnchors, subject != .animation, let figure = figure(labelled: label, in: figures) {
                        beats[beatIndex].figureLabel = figure.label
                    } else {
                        warnings.append("Beat \(beatIndex + 1) of step \(position) names \(label), which has no figure to outline here; the beat keeps its words and points nowhere of its own.")
                        beats[beatIndex].figureLabel = nil
                        beats[beatIndex].panelLabel = nil
                    }
                } else if beat.panelLabel != nil, step.anchor?.figureLabel == nil {
                    beats[beatIndex].panelLabel = nil
                }
            }
            step.beats = beats.isEmpty ? nil : beats
            if step.kind == .figure, step.anchor?.figureLabel == nil {
                // Without a figure to outline it is an explanation. The words
                // stay; only the Reader's treatment of the step changes.
                step.kind = .explain
            }
            // The authors' own sentence about the panel, for the chat to
            // repeat under the step. Read off the text here, where the text
            // is, and kept in the record so playing a step costs a string.
            if let label = step.anchor?.figureLabel {
                step.sourceMention = PaperFigureMention.sentence(citing: label, panel: step.anchor?.panelLabel, in: text)
            }

            // Picture. A step that outlines a figure shows that figure, so a
            // picture of its own is dropped; a figure picture is checked as
            // an anchor is, and a drawn picture's id as the store names them.
            if let picture = raw.picture, !picture.isEmpty {
                if subject == .animation {
                    warnings.append("Step \(position) names a picture, but a walkthrough of an animation shows the animation; the picture was dropped.")
                } else if step.anchor?.figureLabel == nil {
                    var settled = PaperWalkthroughPicture()
                    if let label = picture.figureLabel {
                        if !allowsFigureAnchors {
                            warnings.append("Step \(position)'s picture names \(label), but this source is shown as text and has no figures; brief a picture to draw instead.")
                        } else if let figure = figure(labelled: label, in: figures) {
                            settled.figureLabel = figure.label
                            settled.panelLabel = picture.panelLabel
                        } else {
                            warnings.append("Step \(position)'s picture names \(label), which the paper's figure index does not have; the picture was dropped.")
                        }
                    }
                    if settled.figureLabel == nil {
                        settled.brief = picture.brief
                        if let id = picture.imageID?.lowercased() {
                            if PaperWalkthroughPicture.isValidImageID(id) {
                                settled.imageID = id
                            } else {
                                warnings.append("Step \(position)'s picture names image \(id), which is not an image id; the picture was dropped.")
                            }
                        }
                    }
                    step.picture = settled.isEmpty ? nil : settled
                }
            }

            // Question. Each kind is asked only with what it is checked
            // against (the lesson's rule): a Find it
            // needs a figure with the target among its panels, a Predict a
            // figure to hide — one without is asked as Think first — and
            // every kind a reference answer.
            if let quiz = raw.quiz {
                if quiz.isValid {
                    var settled = PaperWalkthroughQuiz(
                        question: quiz.question.trimmingCharacters(in: .whitespacesAndNewlines),
                        answer: quiz.answer.trimmingCharacters(in: .whitespacesAndNewlines),
                        keyPoints: quiz.keyPoints
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty },
                        kind: quiz.kind,
                        targetPanel: quiz.targetPanel
                    )
                    switch settled.kind {
                    case .find:
                        let figure = step.anchor?.figureLabel.flatMap { self.figure(labelled: $0, in: figures) }
                        let requested = settled.targetPanel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let target = panelKey(requested)
                        if figure == nil {
                            warnings.append("Step \(position) asks the learner to find a panel but points at no figure; it is asked as a plain question.")
                            settled.kind = .recall
                            settled.targetPanel = nil
                        } else if let target, let figure,
                                  figure.panelLabels.isEmpty || figure.panelLabels.contains(where: { panelKey($0) == target }) {
                            // A letter lower-cased, as the record keeps panels
                            // ("b"); a name as the figure prints it ("DESIGN"),
                            // so the chip picked and the answer shown agree.
                            if let letter = panelLetter(requested) {
                                settled.targetPanel = letter.lowercased()
                            } else {
                                settled.targetPanel = panelDisplayName(figure.panelLabels.first { panelKey($0) == target } ?? requested)
                            }
                            // The whole figure is shown so every panel can be picked.
                            step.anchor?.panelLabel = nil
                        } else if let figure {
                            let printed = figure.panelLabels.isEmpty ? "no listed panels" : "panels \(figure.panelLabels.joined(separator: ", "))"
                            warnings.append("Step \(position) asks the learner to find panel \(settled.targetPanel ?? "?") of \(figure.label), which prints \(printed); it is asked as a plain question.")
                            settled.kind = .recall
                            settled.targetPanel = nil
                        }
                    case .predict:
                        if step.anchor?.figureLabel == nil {
                            warnings.append("Step \(position) asks for a prediction but points at no figure to hide; it is asked as Think first.")
                            settled.kind = .thinkFirst
                        }
                        settled.targetPanel = nil
                    case .recall, .thinkFirst:
                        settled.targetPanel = nil
                    }
                    step.quiz = settled
                    step.kind = .quiz
                } else {
                    warnings.append("Step \(position) had a question without a reference answer; the question was dropped.")
                    if step.kind == .quiz { step.kind = .explain }
                }
            } else if step.kind == .quiz {
                step.kind = .explain
            }

            // Animation by reference: a saved animation pinned to one of its
            // steps. Not counted against the inline limit, since nothing is
            // stored per step but an id and a number.
            if let reference = raw.animation {
                let animationID = reference.animationID.trimmingCharacters(in: .whitespacesAndNewlines)
                if animationID.isEmpty {
                    warnings.append("Step \(position) names an animation without its id; the reference was dropped.")
                } else if reference.step < 1 {
                    warnings.append("Step \(position) names step \(reference.step) of an animation; steps count from 1. The reference was dropped.")
                } else {
                    var conditions: [String: String] = [:]
                    for (key, value) in reference.conditions {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !k.isEmpty, !v.isEmpty { conditions[k] = v }
                    }
                    step.animation = WalkthroughAnimationReference(animationID: animationID, step: reference.step, conditions: conditions)
                }
            }

            // Animation, inline.
            if let html = raw.animationHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
                if step.animation != nil {
                    warnings.append("Step \(position) carried both an inline animation and a reference to a saved one; the reference is kept and the inline document was dropped.")
                } else if html.count > maximumAnimationCharacters {
                    warnings.append("Step \(position)'s animation is \(html.count) characters, over the \(maximumAnimationCharacters) allowed; it was dropped.")
                } else if animations >= maximumAnimationsPerWalkthrough {
                    warnings.append("Step \(position)'s animation was dropped: a walkthrough carries at most \(maximumAnimationsPerWalkthrough).")
                } else {
                    step.animationHTML = html
                    animations += 1
                }
            }
            steps.append(step)
        }

        guard !steps.isEmpty else { throw Failure.noSteps }

        // A figure the walk outlines has every known panel addressed, its
        // panels come in order, and the figures come in printed order. The
        // walk teaches claims, and a figure the walk shows is still addressed
        // whole (the product owner's 2026-09-19 rule).
        for gap in panelCoverageGaps(steps: steps, figures: figures) {
            warnings.append(
                "The steps about \(gap.figureLabel) leave panel\(gap.missingPanels.count == 1 ? "" : "s") "
                    + gap.missingPanels.joined(separator: ", ")
                    + " unaddressed; a walk addresses every panel of a figure it shows before it leaves it."
            )
        }
        warnings.append(contentsOf: panelOrderWarnings(steps: steps, figures: figures))
        warnings.append(contentsOf: figureOrderWarnings(steps: steps))

        // Chapters: the plans' steps that survived, in order; a chapter left
        // with none is dropped, one with no claim is kept and said so, and a
        // step no chapter names joins the chapter before it (or the first).
        var chapters: [PaperWalkthroughChapter]?
        if let chapterPlans, !chapterPlans.isEmpty {
            let keptIDs = Set(steps.map(\.id))
            var built: [PaperWalkthroughChapter] = []
            for (offset, plan) in chapterPlans.enumerated() {
                let ids = plan.stepIDs.filter { keptIDs.contains($0) }
                guard !ids.isEmpty else {
                    warnings.append("Chapter \(offset + 1) had no usable steps and was dropped.")
                    continue
                }
                let chapterTitle = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
                var claim = plan.claim.trimmingCharacters(in: .whitespacesAndNewlines)
                if claim.isEmpty {
                    warnings.append("Chapter \(offset + 1) states no claim; its recap has nothing to say back.")
                    claim = ""
                }
                built.append(PaperWalkthroughChapter(
                    id: "ch-\(built.count + 1)",
                    title: chapterTitle.isEmpty ? "Chapter \(built.count + 1)" : chapterTitle,
                    claim: claim,
                    stepIDs: ids
                ))
            }
            if !built.isEmpty {
                let named = Set(built.flatMap(\.stepIDs))
                var previous = 0
                for step in steps {
                    if let index = built.firstIndex(where: { $0.stepIDs.contains(step.id) }) {
                        previous = index
                    } else if !named.contains(step.id) {
                        built[previous].stepIDs.append(step.id)
                    }
                }
                // Each chapter's steps in the walk's order.
                let order = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) })
                for index in built.indices {
                    built[index].stepIDs.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
                }
                chapters = built
            }
        }

        let walkthrough = PaperWalkthrough(
            sourceID: sourceID,
            sourceSHA256: sourceSHA256,
            subject: subject,
            title: trimmedTitle,
            steps: steps,
            chapters: chapters,
            generatedAt: generatedAt,
            author: author
        )
        return Outcome(walkthrough: walkthrough, warnings: warnings)
    }

    static let maximumCitesPerStep = 3

    /// A step's cited works as the record keeps them: each with a title, a
    /// DOI only when it is one (a doi.org address given as `url` is read as
    /// the DOI), an address only when it is a web page, and a
    /// `foreverlm://source/<id>` link read as the library id. A work cited
    /// twice is kept once, and a citation of the walked source itself is
    /// dropped: the Reader beside the card already shows it.
    static func citations(
        _ raw: [PaperWalkthroughCitation],
        stepPosition position: Int,
        walkedSourceID: String,
        warnings: inout [String]
    ) -> [PaperWalkthroughCitation] {
        func text(_ value: String?) -> String? {
            let collapsed = (value ?? "")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        var kept: [PaperWalkthroughCitation] = []
        var seen = Set<String>()
        for citation in raw {
            guard let title = text(citation.title) else {
                warnings.append("Step \(position) cites a work with no title; the citation was dropped.")
                continue
            }
            var settled = PaperWalkthroughCitation(
                title: title,
                authors: text(citation.authors),
                year: text(citation.year),
                venue: text(citation.venue),
                kind: citation.kind,
                sourceID: text(citation.sourceID)
            )
            if let given = text(citation.doi) {
                if let doi = PaperWalkthroughCitation.normalizedDOI(given) {
                    settled.doi = doi
                } else {
                    warnings.append("Step \(position) cites “\(title)” with doi \(given), which is not a DOI; the work is kept without it.")
                }
            }
            if let given = text(citation.url) {
                let parsed = URL(string: given)
                let scheme = parsed?.scheme?.lowercased()
                if scheme == "foreverlm", parsed?.host?.lowercased() == "source",
                   let id = parsed?.pathComponents.first(where: { $0 != "/" }), !id.isEmpty {
                    settled.sourceID = settled.sourceID ?? id
                } else if settled.doi == nil, let doi = PaperWalkthroughCitation.normalizedDOI(given) {
                    settled.doi = doi
                } else if let parsed, scheme == "http" || scheme == "https", parsed.host?.isEmpty == false {
                    settled.url = parsed.absoluteString
                } else {
                    warnings.append("Step \(position) cites “\(title)” at \(given), which is not a web address; the work is kept without it.")
                }
            }
            if let id = settled.sourceID, id == walkedSourceID {
                warnings.append("Step \(position) cites the source it walks through; the Reader already shows it, so the citation was dropped.")
                continue
            }
            guard seen.insert(settled.identityKey).inserted else { continue }
            kept.append(settled)
        }
        if kept.count > maximumCitesPerStep {
            warnings.append("Step \(position) cites \(kept.count) works; the first \(maximumCitesPerStep) were kept.")
            kept = Array(kept.prefix(maximumCitesPerStep))
        }
        return kept
    }

    /// The writer's draft as steps, for the check above. Ids are the step's
    /// place in the whole draft, so `chapterPlans(from:)` names the same ids.
    static func steps(from draft: PaperWalkthroughDraft) -> [PaperWalkthroughStep] {
        draft.steps.enumerated().map { index, raw in
            let kind = PaperWalkthroughStep.Kind(rawValue: raw.kind.lowercased()) ?? .explain
            let anchor = PaperWalkthroughAnchor(
                figureLabel: raw.figureLabel,
                panelLabel: raw.panelLabel,
                passage: raw.passage,
                pageNumber: raw.pageNumber
            )
            return PaperWalkthroughStep(
                id: "step-\(index + 1)",
                kind: kind,
                title: raw.title,
                body: raw.body,
                anchor: anchor.isEmpty ? nil : anchor,
                animationHTML: nil,
                animationBrief: raw.animationBrief,
                quiz: raw.quiz,
                beats: raw.beats,
                more: raw.more,
                picture: raw.picture,
                cites: raw.cites
            )
        }
    }

    /// The draft's chapters as plans over the ids `steps(from:)` gives; nil
    /// for a flat draft.
    static func chapterPlans(from draft: PaperWalkthroughDraft) -> [ChapterPlan]? {
        guard let chapters = draft.chapters, !chapters.isEmpty else { return nil }
        var plans: [ChapterPlan] = []
        var position = 0
        for chapter in chapters {
            let ids = chapter.steps.indices.map { _ in
                position += 1
                return "step-\(position)"
            }
            plans.append(ChapterPlan(title: chapter.title, claim: chapter.claim, stepIDs: ids))
        }
        return plans
    }

    /// The label match the tools use: case-folded, blind to "Fig." versus
    /// "Figure", and forgiving of a trailing panel letter glued to the label
    /// ("Figure 2a" finds Figure 2 when no figure is labelled that way).
    static func figure(
        labelled label: String,
        in figures: [PaperWalkthroughFigureReference]
    ) -> PaperWalkthroughFigureReference? {
        let needle = canonicalLabel(label)
        if let exact = figures.first(where: { canonicalLabel($0.label) == needle }) {
            return exact
        }
        // "figure 2a" → "figure 2"
        let stripped = needle.replacingOccurrences(
            of: #"(\d)[a-z]+$"#,
            with: "$1",
            options: .regularExpression
        )
        guard stripped != needle else { return nil }
        return figures.first { canonicalLabel($0.label) == stripped }
    }

    static func canonicalLabel(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "fig.", with: "figure")
            .replacingOccurrences(of: "fig ", with: "figure ")
            .replacingOccurrences(of: "figure", with: "figure ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// Whitespace collapsed, case folded, line-break hyphens joined: the shape
    /// both the passage and the text are compared in.
    static func normalized(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacingOccurrences(of: "-\n", with: "")
        value = value.replacingOccurrences(of: "\u{00AD}", with: "")
        value = value.replacingOccurrences(of: "\u{2019}", with: "'")
        value = value.replacingOccurrences(of: "\u{201C}", with: "\"")
        value = value.replacingOccurrences(of: "\u{201D}", with: "\"")
        value = value.replacingOccurrences(of: "\u{FB01}", with: "fi")
        value = value.replacingOccurrences(of: "\u{FB02}", with: "fl")
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The passage cut to what the Reader needs to find it.
    static func clippedPassage(_ passage: String) -> String {
        let words = passage.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard words.count > maximumPassageWords else { return words.joined(separator: " ") }
        return words.prefix(maximumPassageWords).joined(separator: " ")
    }

    // MARK: Panel coverage

    /// Panels of a figure the walk visits without addressing them.
    struct PanelCoverageGap: Equatable, Sendable {
        let figureLabel: String
        /// Upper-case letters, or names as the figure prints them
        /// (`panelDisplayName`), in the figure's order.
        let missingPanels: [String]
    }

    /// The rule the product owner set on 2026-09-19 ("there can be a walkthrough of
    /// figure 3; but then all the subfigures have to be addressed"), warned
    /// about: for every figure whose panels are known
    /// and that at least one step is anchored to, the steps anchored to it
    /// must together mention every panel — by anchoring to it, by a beat
    /// pointing at it, or by naming it in the title, body or a beat ("panel
    /// B", "panels C and D", "Figure 3E", "(A)"). A beat of another step
    /// that points at one of its panels counts too. A figure no step visits
    /// is the supplement rule's business, not this one's.
    static func panelCoverageGaps(
        steps: [PaperWalkthroughStep],
        figures: [PaperWalkthroughFigureReference]
    ) -> [PanelCoverageGap] {
        var gaps: [PanelCoverageGap] = []
        for figure in figures where !figure.panelLabels.isEmpty {
            let key = canonicalLabel(figure.label)
            guard steps.contains(where: { $0.anchor?.figureLabel.map(canonicalLabel) == key }) else { continue }
            var mentioned = Set<String>()
            for step in steps {
                if step.anchor?.figureLabel.map(canonicalLabel) == key {
                    mentioned.formUnion(mentionedPanels(in: step, of: figure))
                } else {
                    for beat in step.beats ?? [] where beat.figureLabel.map(canonicalLabel) == key {
                        if let panel = beat.panelLabel.flatMap(panelKey) { mentioned.insert(panel) }
                    }
                }
            }
            var shown: [String: String] = [:]
            for label in figure.panelLabels {
                if let key = panelKey(label), shown[key] == nil { shown[key] = panelDisplayName(label) }
            }
            let missing = panelKeys(figure.panelLabels).filter { !mentioned.contains($0) }
            if !missing.isEmpty {
                gaps.append(PanelCoverageGap(figureLabel: figure.label, missingPanels: missing.map { shown[$0] ?? $0 }))
            }
        }
        return gaps
    }

    /// Steps anchored to panels of one figure appear in the panels' order:
    /// letters alphabetically, names in the order the figure lists them
    /// (left to right, as the vision pass read them), which `figures`
    /// supplies. A named panel the figure does not list has no place in that
    /// order and is passed over.
    static func panelOrderWarnings(
        steps: [PaperWalkthroughStep],
        figures: [PaperWalkthroughFigureReference] = []
    ) -> [String] {
        var warnings: [String] = []
        var lastByFigure: [String: (position: Int, key: String, shown: String)] = [:]
        for (index, step) in steps.enumerated() {
            guard let anchor = step.anchor, let label = anchor.figureLabel,
                  let panelLabel = anchor.panelLabel, let panel = panelKey(panelLabel) else { continue }
            let listed = figure(labelled: label, in: figures).map { panelKeys($0.panelLabels) } ?? []
            let isLetter = panelLetter(panelLabel) != nil
            guard isLetter || listed.contains(panel) else { continue }
            let key = canonicalLabel(label)
            let shown = panelDisplayName(panelLabel)
            if let last = lastByFigure[key], panelComesBefore(panel, last.key, listed: listed) {
                warnings.append(
                    "Step \(index + 1) (\(label) \(shown)) comes after step \(last.position) (\(label) \(last.shown)); a figure's panels are walked in order."
                )
            }
            lastByFigure[key] = (index + 1, panel, shown)
        }
        return warnings
    }

    /// Where a figure falls in its series' printed order.
    struct FigureOrdinal: Equatable, Sendable {
        /// The label without its number: "figure", "figure s",
        /// "extended data figure".
        let series: String
        /// "Figure 3" → [3]; a textbook's "Figure 3–5" → [3, 5].
        let numbers: [Int]
    }

    /// "Figure 3" → figure [3], "Fig. S2" → figure s [2], "Extended Data
    /// Fig. 4" → extended data figure [4]. Nil for a label with no number.
    static func figureOrdinal(of label: String) -> FigureOrdinal? {
        let canonical = canonicalLabel(label)
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?)\s*([a-z]?)(\d+(?:[.\-–]\d+)*)$"#) else { return nil }
        let range = NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
        guard let match = regex.firstMatch(in: canonical, range: range), match.numberOfRanges > 3,
              let nameRange = Range(match.range(at: 1), in: canonical),
              let letterRange = Range(match.range(at: 2), in: canonical),
              let numberRange = Range(match.range(at: 3), in: canonical) else { return nil }
        let numbers = canonical[numberRange].split(whereSeparator: { ".-–".contains($0) }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        let name = canonical[nameRange].trimmingCharacters(in: .whitespaces)
        let letter = String(canonical[letterRange])
        return FigureOrdinal(series: letter.isEmpty ? name : name + " " + letter, numbers: numbers)
    }

    /// The walk meets the figures in printed order unless the argument needs
    /// otherwise (one walk outlined Figure 3 at its third step, before
    /// Figures 1 and 2). Names each step that first outlines a figure while a lower-numbered
    /// figure of the same series is first outlined later; an extended-data or
    /// supplementary figure is a series of its own, placed beside the main
    /// figure it supports, and a figure the walk never outlines is not
    /// jumped. A question pointing at a figure counts, since the Reader
    /// outlines it too; a step's picture does not.
    static func figureOrderWarnings(steps: [PaperWalkthroughStep]) -> [String] {
        var firsts: [(position: Int, label: String, ordinal: FigureOrdinal)] = []
        var seen = Set<String>()
        for (index, step) in steps.enumerated() {
            guard let label = step.anchor?.figureLabel,
                  seen.insert(canonicalLabel(label)).inserted,
                  let ordinal = figureOrdinal(of: label) else { continue }
            firsts.append((index + 1, label, ordinal))
        }
        var warnings: [String] = []
        for (offset, first) in firsts.enumerated() {
            let jumped = firsts[(offset + 1)...]
                .filter { $0.ordinal.series == first.ordinal.series && $0.ordinal.numbers.lexicographicallyPrecedes(first.ordinal.numbers) }
                .map { "\($0.label) (first at step \($0.position))" }
            guard let last = jumped.last else { continue }
            let named = jumped.count == 1 ? last : jumped.dropLast().joined(separator: ", ") + " and " + last
            warnings.append(
                "Step \(first.position) outlines \(first.label) before \(named); a walk meets the figures in printed order unless the argument needs otherwise, and a step that jumps ahead says why in its first beat."
            )
        }
        return warnings
    }

    /// Whether panel key `first` comes before `second`: two letters by the
    /// alphabet, as they always were compared; otherwise by their places in
    /// the figure's `listed` keys, when both have one.
    private static func panelComesBefore(_ first: String, _ second: String, listed: [String]) -> Bool {
        if first.count == 1, second.count == 1, first.first?.isLetter == true, second.first?.isLetter == true {
            return first < second
        }
        guard let firstPlace = listed.firstIndex(of: first), let secondPlace = listed.firstIndex(of: second) else {
            return false
        }
        return firstPlace < secondPlace
    }

    /// The panels of `figure` a step addresses, as keys (`panelKey`): its
    /// anchor's panel, the panel each of its beats points at, every letter
    /// its title, body or beats name as a panel, and every named panel of
    /// the figure they name.
    static func mentionedPanels(in step: PaperWalkthroughStep, of figure: PaperWalkthroughFigureReference) -> Set<String> {
        var found = Set<String>()
        if let panel = step.anchor?.panelLabel.flatMap(panelKey) { found.insert(panel) }
        // A beat without a figure of its own points at the step's figure.
        let key = canonicalLabel(figure.label)
        let ownBeats = (step.beats ?? []).filter {
            ($0.figureLabel ?? step.anchor?.figureLabel).map(canonicalLabel) == key
        }
        for beat in ownBeats {
            if let panel = beat.panelLabel.flatMap(panelKey) { found.insert(panel) }
        }
        let text = ([step.title, step.body] + ownBeats.map(\.text)).joined(separator: "\n")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // "the DESIGN column", "Design narrows it": a name is found as words.
        let words = normalized(text)
        for name in panelKeys(figure.panelLabels) where panelLetter(name) == nil && name.last?.isLetter == true {
            guard let regex = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            ) else { continue }
            if regex.firstMatch(in: words, range: NSRange(words.startIndex..<words.endIndex, in: words)) != nil {
                found.insert(name)
            }
        }
        // "panel B", "panels C and D", "panels B–D", "panels a, b and c".
        if let regex = try? NSRegularExpression(
            pattern: #"\bpanels?\s+([A-Za-z](?:\s*(?:,|and|to|–|-|&)\s*[A-Za-z])*)\b"#,
            options: [.caseInsensitive]
        ) {
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let listRange = Range(match.range(at: 1), in: text) else { continue }
                found.formUnion(lettersInList(String(text[listRange])))
            }
        }
        // "Figure 3E", "Fig. 3e", "3E" — the figure's own number, then a letter.
        if let number = figureNumber(of: figure.label),
           let regex = try? NSRegularExpression(
               pattern: #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: number) + #"([A-Za-z])\b"#,
               options: [.caseInsensitive]
           ) {
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let letterRange = Range(match.range(at: 1), in: text) else { continue }
                found.insert(text[letterRange].uppercased())
            }
        }
        // "(A)", "(b)".
        if let regex = try? NSRegularExpression(pattern: #"\(([A-Za-z])\)"#) {
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let letterRange = Range(match.range(at: 1), in: text) else { continue }
                found.insert(text[letterRange].uppercased())
            }
        }
        return found
    }

    /// "B, C and E" → B, C, E; "B–D" → B, C, D.
    static func lettersInList(_ list: String) -> Set<String> {
        var letters = Set<String>()
        let normalized = list.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: " to ", with: "-", options: .caseInsensitive)
        let parts = normalized.components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap {
            $0.components(separatedBy: " and ")
        }
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let ends = trimmed.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if ends.count == 2, let first = ends[0].unicodeScalars.first, let last = ends[1].unicodeScalars.first,
               ends[0].count == 1, ends[1].count == 1, first.value <= last.value, last.value - first.value < 26 {
                for value in first.value...last.value {
                    if let scalar = Unicode.Scalar(value) { letters.insert(String(Character(scalar)).uppercased()) }
                }
            } else if trimmed.count == 1, trimmed.first?.isLetter == true {
                letters.insert(trimmed.uppercased())
            }
        }
        return letters
    }

    // MARK: Panel identity

    /// The letter a lettered panel's label names, upper-cased: "a", "A",
    /// "(a)", "1a", "Figure 2B", "panels c and d" → "A", "A", "A", "A", "B",
    /// "D". Nil for a named panel — a label that ends in a word rather than
    /// a letter: "DESIGN", "ALL OF BIOLOGY", "ii" — and for a label that
    /// does not end in a letter. A name does not count as its last letter:
    /// the four columns of a funnel figure labelled ALL OF BIOLOGY, FUNCTION
    /// RETRIEVAL, DESIGN and VALIDATION would be Y, L, N and N, and
    /// VALIDATION's rectangle would take DESIGN's place.
    static func panelLetter(_ label: String) -> String? {
        let trimmed = trimmedPanelLabel(label)
        guard let last = trimmed.last, last.isLetter,
              trimmed.reversed().prefix(while: \.isLetter).count == 1 else { return nil }
        return String(last).uppercased()
    }

    /// What two labels must share to name the same panel: a lettered
    /// panel's letter (`panelLetter`), so "a", "(A)" and "Figure 2a" are one
    /// panel; any other label's name, case-folded with its whitespace
    /// collapsed ("ALL OF  BIOLOGY" → "all of biology"). A letter is one
    /// upper-case character and a name never is, so the two never meet.
    /// Nil for a label that names no panel: empty, or a figure's label alone.
    static func panelKey(_ label: String) -> String? {
        if let letter = panelLetter(label) { return letter }
        let name = panelName(label)
        return name.isEmpty ? nil : name.lowercased()
    }

    /// Whether two labels name the same panel.
    static func samePanel(_ first: String, _ second: String) -> Bool {
        guard let key = panelKey(first) else { return false }
        return panelKey(second) == key
    }

    /// The panel as the learner reads it: a letter upper-cased ("B"), a name
    /// as the figure prints it ("ALL OF BIOLOGY", "Design").
    static func panelDisplayName(_ label: String) -> String {
        panelLetter(label) ?? panelName(label)
    }

    /// A figure's label with a panel's: a letter glued on as papers print it
    /// ("Figure 2" and "b" → "Figure 2b"), a name set off by a space
    /// ("Figure 3 DESIGN"). The figure's label alone when `panel` is nil or
    /// names no panel.
    static func figurePanelLabel(_ figureLabel: String, panel: String?) -> String {
        guard let panel, panelKey(panel) != nil else { return figureLabel }
        if panelLetter(panel) != nil { return figureLabel + panel }
        return figureLabel + " " + panelName(panel)
    }

    /// A figure's listed panels as keys, in the figure's own order (left to
    /// right, as the vision pass read them), each once.
    static func panelKeys(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap(panelKey).filter { seen.insert($0).inserted }
    }

    private static func trimmedPanelLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]."))
    }

    /// A named panel's label as printed, with a leading figure label
    /// ("Figure 3 DESIGN", "Fig. 3: Design") or "panel" dropped and its
    /// whitespace collapsed; empty when nothing else is left.
    private static func panelName(_ label: String) -> String {
        var name = trimmedPanelLabel(label)
        if let prefix = panelNamePrefix {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = prefix.firstMatch(in: name, range: range), let found = Range(match.range, in: name) {
                name.removeSubrange(found)
            }
        }
        return name
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[].,:;|-–—")))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let panelNamePrefix = try? NSRegularExpression(
        pattern: #"^(?:(?:(?:extended\s+data|supplementary|supplemental)\s+)?(?:figure|fig\.?)\s*[A-Za-z]?\d+(?:[.\-–]\d+)?\b)?[\s,:;|\-–—]*(?:panels?\s+)?"#,
        options: [.caseInsensitive]
    )

    /// "Figure 3" → "3", "Fig. S2" → "S2", "Extended Data Fig. 4" → "4".
    static func figureNumber(of label: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z]?\d+(?:[.\-–]\d+)?)\s*$"#) else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[numberRange])
    }
}
