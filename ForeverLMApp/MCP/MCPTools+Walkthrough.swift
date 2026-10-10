#if os(macOS)
import Foundation

/// The walkthrough tools (walkthrough-design.md): what the Reader's Walk
/// Through button does, reachable from Claude, Codex and the in-app chat.
///
/// `generate_walkthrough` runs the app's own writer; `save_walkthrough` lets an
/// assistant author the steps itself — the in-Reader form of the figure
/// companion sites it used to build as separate pages — with the same anchor
/// checks the writer's draft goes through; `get_walkthrough` reads the steps
/// back; `delete_walkthrough` removes them. One record a source, whoever wrote
/// it. The source is a paper, a book chapter, an article or a YouTube video
/// (`PaperWalkthroughSubject`); a source shown as text takes passage anchors
/// only, and a figure anchor on one is refused by name in `warnings`. A
/// video's steps point at moments of the talk (`at`), and only
/// `save_walkthrough` writes one: the app's writer walks text.
///
/// Since 2026-09-20 a saved animation is a subject too (`animation` in place
/// of `source_id`): its walk's steps pin the animation's page to its own
/// steps (`animation_step`, `animation_conditions`), and any walk's step may
/// show a saved animation that way (`animation` on the step). The chat plays
/// an animation walk beside the animation as it plays a source's beside the
/// Reader; there is no writer for one — `save_walkthrough` is its one route,
/// and a kit animation's build emits the steps (mitochondria
/// `animations/kit/build.py --walkthrough`).
extension MCPDataStore {

    /// What a walkthrough tool call is about: a source, or a saved animation.
    enum WalkthroughToolSubject {
        case source(StudioArticle)
        case animation(ArtifactRecord)

        var id: String {
            switch self {
            case .source(let article): return article.id
            case .animation(let artifact): return artifact.id
            }
        }

        var title: String {
            switch self {
            case .source(let article): return article.title
            case .animation(let artifact): return artifact.title
            }
        }

        /// "paper", "chapter", "article" or "animation".
        var noun: String {
            switch self {
            case .source(let article): return PaperWalkthroughSubject.of(article)?.noun ?? "source"
            case .animation: return "animation"
            }
        }

        var article: StudioArticle? {
            if case .source(let article) = self { return article }
            return nil
        }
    }

    /// The subject a call names: `animation` (an animation's id, slug or
    /// address) or `source_id`. One of the two, never both.
    private func walkthroughToolSubject(arguments: [String: Any]) async throws -> WalkthroughToolSubject {
        let animationHandle = Self.trimmedOrNil(arguments["animation"] as? String)
        let sourceToken = Self.trimmedOrNil(arguments["source_id"] as? String)
        if let animationHandle {
            guard sourceToken == nil else {
                throw MCPError.invalidInput("Pass source_id or animation, not both: a walkthrough is of one source or one animation.")
            }
            return .animation(try await walkthroughAnimation(handle: animationHandle, context: "animation"))
        }
        guard sourceToken != nil else {
            throw MCPError.invalidInput("source_id or animation is required: the paper, book chapter or article from list_sources or a search, or the animation's id, slug or address from list_animations.")
        }
        return .source(try await walkthroughSubjectSource(arguments: arguments))
    }

    /// The animation a handle names — its id or library address, or a
    /// published copy's slug or address —
    /// refused when it names nothing of the learner's, or a Site.
    private func walkthroughAnimation(handle: String, context: String) async throws -> ArtifactRecord {
        guard let found = try await existingSiteArtifact(handle: handle) else {
            throw MCPError.invalidInput("No animation of yours answers to \(handle) (\(context)). Pass its animation_id from list_animations.")
        }
        guard found.isAnimation else {
            throw MCPError.invalidInput("\"\(found.title)\" is a Site, not an animation (\(context)). A walkthrough shows saved animations; a Site is embedded on a page instead.")
        }
        return found
    }

    private enum WalkthroughSourceLookup {
        case found(StudioArticle)
        case notFound
        case excluded
    }

    /// Through the storage actor, never the cached connection: generate_walkthrough
    /// is off the store gate (`storeGateExemptToolNames`) for its minutes of writing.
    private func walkthroughSource(forRequestedID requestedID: String) async throws -> WalkthroughSourceLookup {
        guard let resolvedID = try await notebookFileStorage.resolveSourceID(forLinkToken: requestedID) else {
            return .notFound
        }
        let excluded = try await notebookFileStorage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !excluded.contains(resolvedID) else { return .excluded }
        guard let article = try await notebookFileStorage.loadPersistedSources(ids: [resolvedID]).first else {
            return .notFound
        }
        return .found(article)
    }

    func walkthroughSubjectSource(arguments: [String: Any]) async throws -> StudioArticle {
        let requested = ((arguments["source_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw MCPError.invalidInput("source_id is required: the paper, book chapter or article, from list_sources or a search result.")
        }
        switch try await walkthroughSource(forRequestedID: requested) {
        case .found(let article):
            return article
        case .notFound:
            throw MCPError.invalidInput(ReviewSessionManager.sourceNotInLibraryMessage(requested))
        case .excluded:
            throw MCPError.invalidInput(
                "This source is excluded from knowledge search and AI in ForeverLM Settings › Sources. Include its source family there first."
            )
        }
    }

    /// A step's `beats` as sent: each a sentence, or `{text, figure_label,
    /// panel_label}` for a beat that points at a panel of its own. Nil when
    /// none was sent, so the step is cut from its body.
    static func walkthroughBeats(_ value: Any?) -> [PaperWalkthroughBeat]? {
        guard let list = value as? [Any] else { return nil }
        let beats = list.compactMap { item -> PaperWalkthroughBeat? in
            if let text = item as? String { return PaperWalkthroughBeat(text: text) }
            guard let object = item as? [String: Any], let text = object["text"] as? String else { return nil }
            return PaperWalkthroughBeat(
                text: text,
                figureLabel: object["figure_label"] as? String,
                panelLabel: object["panel_label"] as? String
            )
        }
        return beats.isEmpty ? nil : beats
    }

    /// The noun the results use for the source: "paper", "chapter", "article".
    private static func walkthroughNoun(_ article: StudioArticle) -> String {
        PaperWalkthroughSubject.of(article)?.noun ?? "source"
    }

    // MARK: generate_walkthrough

    func generateWalkthrough(arguments: [String: Any]) async throws -> String {
        if Self.trimmedOrNil(arguments["animation"] as? String) != nil {
            throw MCPError.invalidInput("ForeverLM's writer walks through sources. An animation's walkthrough is saved with save_walkthrough (animation, title, steps with animation_step and animation_conditions); a kit animation's build emits those steps as walkthrough.json.")
        }
        let article = try await walkthroughSubjectSource(arguments: arguments)
        if let subject = PaperWalkthroughSubject.of(article), !subject.writerWrites {
            throw MCPError.invalidInput(
                "ForeverLM's writer does not walk through a \(subject.noun). Write the steps yourself with save_walkthrough: give each step at, the moment of the talk it is about (\"12:34\"), and the Reader holds the video there, paused, while its card is read."
            )
        }
        guard PaperWalkthroughGeneratorService.canWalkThrough(article) else {
            throw MCPError.invalidInput(
                "A walkthrough is written about \(PaperWalkthroughSubject.qualifyingPhrase) whose text has been read; \"\(article.title)\" is not one yet."
            )
        }
        // A connected assistant can author pictures and animations with its
        // own allowance and save them. Omission must not silently choose the
        // separately billed ForeverLM media route.
        let drawsAnimations = arguments["animations"] as? Bool ?? false
        let service = PaperWalkthroughGeneratorService(
            storage: notebookFileStorage,
            backend: LivePaperWalkthroughModelBackend(aiService: AIService()),
            figureIndexer: paperFigureIndexer
        )
        let result: PaperWalkthroughGenerationResult
        let activity = MCPToolActivityReporter.current
        do {
            result = try await service.run(
                request: PaperWalkthroughRequest(sourceID: article.id, drawsAnimations: drawsAnimations),
                onStage: { stage in
                    guard let activity else { return }
                    Task { await activity.report(stage.label) }
                }
            )
        } catch let error as PaperWalkthroughGenerationError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let figures = (try? await notebookFileStorage.paperFigures(sourceID: article.id)) ?? []
        var payload = Self.walkthroughPayload(result.walkthrough, source: article, includeSteps: true, figures: figures, citedSourceIDs: try walkthroughCitedSourceIDs(result.walkthrough))
        payload["status"] = result.replacedExisting ? "rewritten" : "written"
        payload["warnings"] = result.warnings
        payload["animation_failures"] = result.animationFailures
        payload["message"] = (result.replacedExisting
            ? "Rewrote the walkthrough. "
            : "Wrote the walkthrough. ")
            + "The chat beside the \(Self.walkthroughNoun(article)) in the Reader plays it, one step a message; each step scrolls to what it points at."
        return try jsonString(payload)
    }

    // MARK: get_walkthrough

    /// `list_walkthroughs`: every source's walkthrough, newest first, as a
    /// notebook's Studio lists those of its sources (product owner, 2026-09-23:
    /// "walkthroughs need to be dedicated artifacts") — title, source,
    /// subject, counts, author, and whether it still matches the source's
    /// text. The steps themselves are `get_walkthrough`'s.
    func listWalkthroughs(notebookID: String? = nil) async throws -> String {
        // notebook_id: a walkthrough rides its source, so it belongs to every
        // notebook holding that source, a team notebook's copy of it included
        // (`NotebookMembership.containsDerived`).
        let notebook = try await notebookMembershipForListing(notebookID: notebookID)
        // Screen record mode (admin only): the walkthroughs a notebook's
        // Studio shows, of the recording Notebook's sources or written during the take
        // (`ScreenRecordScope.allowsSourceDerived`). A public source the
        // library-sources switch puts on screen does not bring the learner's
        // own walkthrough of it along. Every walkthrough when the mode is off.
        let screenScope = screenRecordScope()
        let summaries = try await notebookFileStorage.paperWalkthroughSummaries()
            .filter { notebook?.containsDerived(sourceID: $0.sourceID) ?? true }
            .filter { screenScope?.allowsSourceDerived(createdAt: $0.generatedAt, sourceID: $0.sourceID) ?? true }
        let loaded = try await notebookFileStorage.loadPersistedSources(ids: Array(Set(summaries.map(\.sourceID))))
        let articles = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let payload: [[String: Any]] = summaries.map { summary in
            var entry: [String: Any] = [
                "source_id": summary.sourceID,
                "title": summary.title,
                "status": summary.status.rawValue,
                "author": summary.author.rawValue,
                "generated_at": ISO8601DateFormatter().string(from: summary.generatedAt),
                "step_count": summary.stepCount,
                "chapter_count": summary.chapterCount,
                "card_count": summary.cardCount,
                "quiz_count": summary.questionCount,
                "figure_step_count": summary.figureStepCount,
                "animation_count": summary.animationCount,
            ]
            if let article = articles[summary.sourceID] {
                entry["source_title"] = article.title
                if let subject = PaperWalkthroughSubject.of(article) {
                    entry["subject"] = subject.rawValue
                }
            }
            return entry
        }
        var result: [String: Any] = [
            "walkthroughs": payload,
            "count": payload.count,
            "message": payload.isEmpty
                ? (notebook == nil
                    ? "No source has a walkthrough yet. Call generate_walkthrough on a paper, a chapter or an article, or save_walkthrough to write the steps yourself."
                    : "No source this Notebook holds has a walkthrough yet. Call generate_walkthrough on one of its papers, chapters or articles.")
                : "\(payload.count) walkthrough\(payload.count == 1 ? "" : "s"), newest first. A stale one was written against text its source no longer carries; generate_walkthrough or save_walkthrough replaces it. get_walkthrough reads a walk's steps.",
        ]
        if let notebook { result["notebook_id"] = notebook.notebookID }
        return try jsonString(result)
    }

    func getWalkthrough(arguments: [String: Any]) async throws -> String {
        let subject = try await walkthroughToolSubject(arguments: arguments)
        if case .animation(let artifact) = subject {
            guard let walkthrough = try await notebookFileStorage.loadArtifactWalkthrough(artifact.id) else {
                let stale = try await notebookFileStorage.hasArtifactWalkthrough(artifact.id)
                return try jsonString([
                    "status": stale ? "stale" : "none",
                    "source_id": artifact.id,
                    "animation_id": artifact.id,
                    "animation_url": artifact.linkedURL as Any? ?? NSNull(),
                    "title": artifact.title,
                    "subject": "animation",
                    "figure_anchors": false,
                    "message": stale
                        ? "The animation's address changed since its walkthrough was written, so it is not shown. Call save_walkthrough with animation set to write a new one."
                        : "This animation has no walkthrough. Call save_walkthrough with animation set to its slug and steps that name its own steps (animation_step, animation_conditions); a kit animation's build writes them as walkthrough.json.",
                ] as [String: Any])
            }
            var payload = try await walkthroughPayload(walkthrough, subject: subject, includeSteps: true)
            payload["status"] = "ok"
            return try jsonString(payload)
        }
        guard let article = subject.article else { throw MCPError.invalidInput("source_id is required.") }
        let noun = Self.walkthroughNoun(article)
        guard var walkthrough = try await notebookFileStorage.loadPaperWalkthrough(article.id) else {
            let stale = try await notebookFileStorage.hasPaperWalkthrough(article.id)
            let writerWrites = PaperWalkthroughSubject.of(article)?.writerWrites ?? true
            let writers = writerWrites
                ? "generate_walkthrough or save_walkthrough"
                : "save_walkthrough"
            var payload: [String: Any] = [
                "status": stale ? "stale" : "none",
                "source_id": article.id,
                "title": article.title,
                "message": stale
                    ? "The \(noun)'s text changed since its walkthrough was written, so it is not shown. Call \(writers) to write a new one."
                    : writerWrites
                        ? "This \(noun) has no walkthrough. Call generate_walkthrough to have ForeverLM write one, or save_walkthrough to write the steps yourself."
                        : "This \(noun) has no walkthrough. Call save_walkthrough to write the steps yourself, each at the moment of the talk it is about.",
            ]
            if let subject = PaperWalkthroughSubject.of(article) {
                payload["subject"] = subject.rawValue
                payload["figure_anchors"] = PaperWalkthroughSubject.allowsFigureAnchors(article)
                if subject.allowsMomentAnchors { payload["moment_anchors"] = true }
            }
            return try jsonString(payload)
        }
        // A record written before figure steps kept the authors' sentence
        // about their panel reads with it, as the chat plays it.
        if walkthrough.needsSourceMentions, let text = await notebookFileStorage.loadSourceContent(article.id), !text.isEmpty {
            walkthrough = walkthrough.fillingSourceMentions(from: text)
        }
        let figures = (try? await notebookFileStorage.paperFigures(sourceID: article.id)) ?? []
        var payload = Self.walkthroughPayload(
            walkthrough,
            source: article,
            includeSteps: true,
            figures: figures,
            animations: try await referencedAnimations(in: walkthrough),
            citedSourceIDs: try walkthroughCitedSourceIDs(walkthrough)
        )
        payload["status"] = "ok"
        return try jsonString(payload)
    }

    /// The animation records a walk's steps refer to, by id, for their
    /// addresses in the payload.
    private func referencedAnimations(in walkthrough: PaperWalkthrough) async throws -> [String: ArtifactRecord] {
        let ids = Set(walkthrough.referencedAnimationIDs)
        guard !ids.isEmpty else { return [:] }
        var found: [String: ArtifactRecord] = [:]
        for artifact in try await notebookFileStorage.loadArtifacts(notebookID: nil) where ids.contains(artifact.id) {
            found[artifact.id] = artifact
        }
        return found
    }

    // MARK: save_walkthrough

    func saveWalkthrough(arguments: [String: Any]) async throws -> String {
        let subject = try await walkthroughToolSubject(arguments: arguments)
        if case .source(let article) = subject, PaperWalkthroughSubject.of(article) == nil {
            throw MCPError.invalidInput(
                "A walkthrough is saved on \(PaperWalkthroughSubject.savableQualifyingPhrase), or on an animation (pass animation); \"\(article.title)\" is a \(article.sourceType.rawValue), not one of those."
            )
        }
        let noun = subject.noun
        let title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPError.invalidInput("title is required.") }
        // The steps come flat, or in chapters — one a claim — whose steps are
        // run together, each chapter remembering which of them are its own.
        var rawSteps: [[String: Any]] = []
        var chapterPlans: [PaperWalkthroughValidation.ChapterPlan]?
        if let rawChapters = arguments["chapters"] as? [[String: Any]], !rawChapters.isEmpty {
            var plans: [PaperWalkthroughValidation.ChapterPlan] = []
            for rawChapter in rawChapters {
                let chapterSteps = (rawChapter["steps"] as? [[String: Any]]) ?? []
                var ids: [String] = []
                for raw in chapterSteps {
                    rawSteps.append(raw)
                    ids.append(Self.stepID(raw, position: rawSteps.count))
                }
                guard !ids.isEmpty else { continue }
                plans.append(PaperWalkthroughValidation.ChapterPlan(
                    title: (rawChapter["title"] as? String) ?? "",
                    claim: (rawChapter["claim"] as? String) ?? "",
                    stepIDs: ids
                ))
            }
            chapterPlans = plans.isEmpty ? nil : plans
        } else if let flat = arguments["steps"] as? [[String: Any]] {
            rawSteps = flat
        }
        guard !rawSteps.isEmpty else {
            throw MCPError.invalidInput("steps is required: a non-empty array of step objects, or chapters each holding its steps.")
        }
        var text = ""
        let sourceSubject = subject.article.flatMap(PaperWalkthroughSubject.of)
        if case .source(let article) = subject {
            guard let content = await notebookFileStorage.loadSourceContent(article.id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                throw MCPError.invalidInput("\"\(article.title)\" has no text yet, so its anchors cannot be checked.")
            }
            // A video's walk is of its talk: held to the transcript, not the
            // slide block its captured slides add.
            text = sourceSubject == .video ? PaperWalkthroughSubject.walkedText(of: content) : content
        }
        // A video step quoting the talk without a moment is placed where the
        // talk says the quote: the transcript knows when, the caller need
        // not work it out.
        let transcriptTimeline = sourceSubject == .video
            ? LectureQuizTimeline(CourseQuizPlanning.lines(from: text))
            : nil

        // A source shown as text has no figure index and nothing to outline; a
        // figure anchor on it is refused by the validator with a warning that
        // says so, whatever an index might hold. For a PDF, the panel letters
        // each figure prints come off the PDF's text layer where the vision
        // pass has not run, so the coverage check below can hold the steps to
        // every panel.
        let allowsFigureAnchors = subject.article.map(PaperWalkthroughSubject.allowsFigureAnchors) ?? false
        let records = allowsFigureAnchors && subject.article != nil
            ? (try? await paperFigureIndexer.prepareStructure(sourceID: subject.id)) ?? []
            : []
        let figures = PaperWalkthroughGeneratorService.figureReferences(
            from: records,
            pdfPath: allowsFigureAnchors ? subject.article?.resolvedLocalPath : nil
        )

        var steps: [PaperWalkthroughStep] = []
        var shapeWarnings: [String] = []
        // Animations the steps name, resolved once each; the subject answers
        // for a step of an animation walk that names no other animation.
        var animationsByHandle: [String: ArtifactRecord] = [:]
        var referencedAnimations: [String: ArtifactRecord] = [:]
        if case .animation(let artifact) = subject { referencedAnimations[artifact.id] = artifact }
        for (index, raw) in rawSteps.enumerated() {
            let kindName = ((raw["kind"] as? String) ?? "explain").lowercased()
            guard let kind = PaperWalkthroughStep.Kind(rawValue: kindName) else {
                throw MCPError.invalidInput(
                    "Step \(index + 1): kind must be one of \(PaperWalkthroughStep.Kind.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            var quiz: PaperWalkthroughQuiz?
            if let rawQuiz = raw["quiz"] as? [String: Any] {
                let question = (rawQuiz["question"] as? String) ?? ""
                if let answer = rawQuiz["answer"] as? String,
                   !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let kindName = ((rawQuiz["kind"] as? String) ?? "recall").lowercased()
                        .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
                    guard let quizKind = PaperWalkthroughQuiz.Kind(rawValue: kindName) else {
                        throw MCPError.invalidInput(
                            "Step \(index + 1): quiz.kind must be one of \(PaperWalkthroughQuiz.Kind.allCases.map(\.rawValue).joined(separator: ", "))."
                        )
                    }
                    quiz = PaperWalkthroughQuiz(
                        question: question,
                        answer: answer,
                        keyPoints: (rawQuiz["key_points"] as? [String]) ?? [],
                        kind: quizKind,
                        targetPanel: Self.trimmedOrNil(rawQuiz["target_panel"] as? String)
                    )
                } else {
                    // The multiple-choice shape accepted before 2026-09-19.
                    // Saved as the open question it becomes in the panel, with
                    // the option marked correct as the reference answer, and
                    // named so the caller moves to the new shape.
                    quiz = PaperWalkthroughQuiz(
                        question: question,
                        answer: PaperWalkthroughQuiz.legacyReferenceAnswer(
                            options: (rawQuiz["options"] as? [String]) ?? [],
                            correctIndex: Self.walkthroughInteger(rawQuiz["correct_index"]),
                            explanation: (rawQuiz["explanation"] as? String) ?? ""
                        )
                    )
                    shapeWarnings.append(
                        "Step \(index + 1) passed a multiple-choice quiz (options, correct_index). Walkthrough questions are open: the learner answers in their own words and the answer is graded against a reference. It was saved as one, with the option marked correct as the reference answer; pass quiz.answer and quiz.key_points instead."
                    )
                }
            }
            var anchor = PaperWalkthroughAnchor(
                figureLabel: raw["figure_label"] as? String,
                panelLabel: raw["panel_label"] as? String,
                passage: raw["passage"] as? String,
                pageNumber: Self.walkthroughInteger(raw["page_number"]),
                seconds: SourceImageReference.timestampSeconds(raw["at"])
            )
            if let at = raw["at"], !(at is NSNull), anchor.seconds == nil {
                shapeWarnings.append("Step \(index + 1): at \"\(at)\" is no moment; pass whole seconds or a clock reading such as \"12:34\".")
            }
            if anchor.seconds == nil, let transcriptTimeline,
               let passage = Self.trimmedOrNil(anchor.passage),
               let said = transcriptTimeline.seconds(saying: passage) {
                anchor.seconds = Int(said)
            }
            // The card's picture: a figure it shows without outlining, a
            // brief to draw, or a picture drawn already (generate_image's
            // image_id), which must be one this Mac holds.
            var picture: PaperWalkthroughPicture?
            if let rawPicture = raw["picture"] as? [String: Any] {
                var imageID: String?
                if let named = ReviewSessionManager.imageID(fromArgument: rawPicture["image_id"]) {
                    let group = await Task.detached(priority: .userInitiated) { GeneratedImageStore.group(containing: named) }.value
                    guard let group else {
                        throw MCPError.invalidInput("Step \(index + 1): picture.image_id \(named) is no image on this Mac. generate_image draws one and list_images names them.")
                    }
                    imageID = group.imageID
                }
                picture = PaperWalkthroughPicture(
                    figureLabel: Self.trimmedOrNil(rawPicture["figure_label"] as? String),
                    panelLabel: Self.trimmedOrNil(rawPicture["panel_label"] as? String),
                    brief: Self.trimmedOrNil(rawPicture["brief"] as? String),
                    imageID: imageID
                )
            }
            // A saved animation the step shows: `animation` names it (or the
            // subject does, in an animation walk), `animation_step` its
            // step, `animation_conditions` the conditions.
            var reference: WalkthroughAnimationReference?
            let stepHandle = Self.trimmedOrNil(raw["animation"] as? String)
            let stepNumber = Self.walkthroughInteger(raw["animation_step"])
            let rawConditions = raw["animation_conditions"] as? [String: Any]
            if stepHandle != nil || stepNumber != nil || rawConditions != nil {
                let artifact: ArtifactRecord
                if let stepHandle {
                    if let cached = animationsByHandle[stepHandle] {
                        artifact = cached
                    } else {
                        artifact = try await walkthroughAnimation(handle: stepHandle, context: "step \(index + 1)")
                        animationsByHandle[stepHandle] = artifact
                    }
                } else if case .animation(let own) = subject {
                    artifact = own
                } else {
                    throw MCPError.invalidInput("Step \(index + 1) names an animation step without the animation: pass animation (its id, slug or address) on the step.")
                }
                referencedAnimations[artifact.id] = artifact
                var conditions: [String: String] = [:]
                for (key, value) in rawConditions ?? [:] {
                    if let text = value as? String { conditions[key] = text }
                    else if let flag = value as? Bool { conditions[key] = flag ? "1" : "0" }
                    else if let number = value as? NSNumber { conditions[key] = number.stringValue }
                }
                reference = WalkthroughAnimationReference(animationID: artifact.id, step: stepNumber ?? 1, conditions: conditions)
            }
            let more: [PaperWalkthroughMore] = ((raw["more"] as? [[String: Any]]) ?? []).compactMap { chip in
                guard let label = Self.trimmedOrNil(chip["label"] as? String),
                      let text = Self.trimmedOrNil(chip["text"] as? String) else { return nil }
                return PaperWalkthroughMore(label: label, text: text, fromPaper: (chip["from_paper"] as? Bool) ?? false)
            }
            let cites = try walkthroughCitations(raw["cites"], stepPosition: index + 1, warnings: &shapeWarnings)
            steps.append(PaperWalkthroughStep(
                id: Self.stepID(raw, position: index + 1),
                kind: kind,
                title: (raw["title"] as? String) ?? "",
                body: (raw["body"] as? String) ?? "",
                anchor: anchor.isEmpty ? nil : anchor,
                animationHTML: raw["animation_html"] as? String,
                animationBrief: raw["animation_brief"] as? String,
                animation: reference,
                quiz: quiz,
                beats: Self.walkthroughBeats(raw["beats"]),
                more: more,
                picture: picture,
                cites: cites
            ))
        }

        let outcome: PaperWalkthroughValidation.Outcome
        do {
            switch subject {
            case .source(let article):
                outcome = try PaperWalkthroughValidation.walkthrough(
                    title: title,
                    steps: steps,
                    chapters: chapterPlans,
                    sourceID: article.id,
                    sourceSHA256: PaperContentPreparationService.sha256(text),
                    figures: figures,
                    allowsFigureAnchors: allowsFigureAnchors,
                    allowsMomentAnchors: sourceSubject?.allowsMomentAnchors ?? false,
                    momentLimit: sourceSubject == .video ? PaperWalkthroughSubject.momentLimit(ofTranscript: text) : nil,
                    text: text,
                    author: .assistant
                )
            case .animation(let artifact):
                outcome = try PaperWalkthroughValidation.walkthrough(
                    title: title,
                    steps: steps,
                    chapters: chapterPlans,
                    sourceID: artifact.id,
                    sourceSHA256: PaperWalkthrough.animationFingerprint(linkedURL: artifact.linkedURL, artifactID: artifact.id),
                    subject: .animation,
                    figures: [],
                    allowsFigureAnchors: false,
                    text: "",
                    author: .assistant
                )
            }
        } catch {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let replaced: Bool
        do {
            switch subject {
            case .source(let article):
                replaced = try await notebookFileStorage.hasPaperWalkthrough(article.id)
                try await notebookFileStorage.savePaperWalkthrough(outcome.walkthrough)
            case .animation(let artifact):
                replaced = try await notebookFileStorage.hasArtifactWalkthrough(artifact.id)
                try await notebookFileStorage.saveArtifactWalkthrough(outcome.walkthrough)
            }
        } catch {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        var payload = try await walkthroughPayload(outcome.walkthrough, subject: subject, includeSteps: false, animations: referencedAnimations)
        payload["status"] = replaced ? "replaced" : "saved"
        payload["warnings"] = shapeWarnings + outcome.warnings
        payload["figures_available"] = figures.map { ["label": $0.label, "page_number": $0.pageNumber] as [String: Any] }
        let plays: String
        switch subject {
        case .source where sourceSubject == .video:
            plays = "The chat beside the video in the Reader plays it, one step a message; each step holds the video at its moment, paused."
        case .source: plays = "The chat beside the \(noun) in the Reader plays it, one step a message."
        case .animation: plays = "The chat beside the animation plays it, one step a message; each step pins the animation to the step it talks about, and a pane showing the animation follows."
        }
        payload["message"] = (replaced ? "Replaced the \(noun)'s walkthrough. " : "Saved the walkthrough. ")
            + plays
            + ((shapeWarnings + outcome.warnings).isEmpty ? "" : " See warnings.")
        return try jsonString(payload)
    }

    // MARK: delete_walkthrough

    func deleteWalkthrough(arguments: [String: Any]) async throws -> String {
        let subject = try await walkthroughToolSubject(arguments: arguments)
        let noun = subject.noun
        let removed: Bool
        switch subject {
        case .source(let article): removed = try await notebookFileStorage.deletePaperWalkthrough(article.id)
        case .animation(let artifact): removed = try await notebookFileStorage.deleteArtifactWalkthrough(artifact.id)
        }
        var payload: [String: Any] = [
            "status": removed ? "deleted" : "none",
            "source_id": subject.id,
            "title": subject.title,
            "message": removed ? "Removed the \(noun)'s walkthrough." : "This \(noun) had no walkthrough.",
        ]
        if case .animation(let artifact) = subject { payload["animation_id"] = artifact.id; payload["subject"] = "animation" }
        return try jsonString(payload)
    }

    /// The payload for either subject: a source's carries its `subject` and
    /// `figure_anchors`; an animation's names the animation and its address.
    private func walkthroughPayload(
        _ walkthrough: PaperWalkthrough,
        subject: WalkthroughToolSubject,
        includeSteps: Bool,
        animations: [String: ArtifactRecord]? = nil
    ) async throws -> [String: Any] {
        let resolvedAnimations: [String: ArtifactRecord]
        if let animations { resolvedAnimations = animations } else { resolvedAnimations = try await referencedAnimations(in: walkthrough) }
        let citedSourceIDs = try includeSteps ? walkthroughCitedSourceIDs(walkthrough) : [:]
        switch subject {
        case .source(let article):
            let figures = includeSteps ? ((try? await notebookFileStorage.paperFigures(sourceID: article.id)) ?? []) : []
            return Self.walkthroughPayload(walkthrough, source: article, includeSteps: includeSteps, figures: figures, animations: resolvedAnimations, citedSourceIDs: citedSourceIDs)
        case .animation(let artifact):
            var payload = Self.walkthroughPayload(walkthrough, sourceTitle: artifact.title, includeSteps: includeSteps, animations: resolvedAnimations, citedSourceIDs: citedSourceIDs)
            payload["subject"] = "animation"
            payload["figure_anchors"] = false
            payload["animation_id"] = artifact.id
            payload["animation_url"] = artifact.linkedURL as Any? ?? NSNull()
            return payload
        }
    }

    // MARK: Payload

    /// The record as the tools return it. `subject` says what was walked
    /// (paper, chapter, article, video) and `figure_anchors` whether its steps
    /// may point at figures at all, so an assistant writing steps for an
    /// article knows to quote passages before it tries; a video's says
    /// `moment_anchors`, its steps' `at`. `figures` is the source's
    /// figure index, for each figure step's printed title and panel caption.
    static func walkthroughPayload(
        _ walkthrough: PaperWalkthrough,
        source: StudioArticle,
        includeSteps: Bool,
        figures: [PaperFigureRecord] = [],
        animations: [String: ArtifactRecord] = [:],
        citedSourceIDs: [String: String] = [:]
    ) -> [String: Any] {
        var payload = walkthroughPayload(walkthrough, sourceTitle: source.title, includeSteps: includeSteps, figures: figures, animations: animations, citedSourceIDs: citedSourceIDs)
        if let subject = PaperWalkthroughSubject.of(source) {
            payload["subject"] = subject.rawValue
            payload["figure_anchors"] = PaperWalkthroughSubject.allowsFigureAnchors(source)
            if subject.allowsMomentAnchors { payload["moment_anchors"] = true }
        }
        return payload
    }

    /// `figures` is the source's figure index, for each figure step's printed
    /// title (`figure_title`) and its panel's caption (`panel_caption`).
    /// `animations` is the records the steps refer to, by id, for each
    /// reference's `url` (the animation's page with the step's walk
    /// parameters) and `title`. `citedSourceIDs` is the library source each
    /// cited work is, by the citation's `identityKey`
    /// (`walkthroughCitedSourceIDs`).
    static func walkthroughPayload(
        _ walkthrough: PaperWalkthrough,
        sourceTitle: String,
        includeSteps: Bool,
        figures: [PaperFigureRecord] = [],
        animations: [String: ArtifactRecord] = [:],
        citedSourceIDs: [String: String] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "source_id": walkthrough.sourceID,
            "source_title": sourceTitle,
            "title": walkthrough.title,
            "author": walkthrough.author.rawValue,
            "generated_at": ISO8601DateFormatter().string(from: walkthrough.generatedAt),
            "step_count": walkthrough.steps.count,
            "card_count": walkthrough.cardCount,
            "chapter_count": walkthrough.chapterCount,
            "quiz_count": walkthrough.quizCount,
            "animation_count": walkthrough.animationCount,
        ]
        if let chapters = walkthrough.chapters, !chapters.isEmpty {
            payload["chapters"] = chapters.map { chapter -> [String: Any] in
                ["id": chapter.id, "title": chapter.title, "claim": chapter.claim, "step_ids": chapter.stepIDs]
            }
        }
        if includeSteps {
            payload["steps"] = walkthrough.steps.map { step -> [String: Any] in
                var entry: [String: Any] = [
                    "id": step.id,
                    "kind": step.kind.rawValue,
                    "title": step.title,
                    "body": step.body,
                    "has_animation": step.hasAnimation,
                ]
                if let reference = step.animation {
                    var animation: [String: Any] = [
                        "animation_id": reference.animationID,
                        "step": reference.step,
                        "conditions": reference.conditions,
                    ]
                    if let record = animations[reference.animationID] {
                        animation["title"] = record.title
                        if let linked = record.linkedURL, let url = URL(string: linked) {
                            animation["url"] = reference.pageURL(animationURL: url).absoluteString
                        }
                    } else {
                        animation["missing"] = true
                    }
                    entry["animation"] = animation
                }
                if let anchor = step.anchor {
                    var anchorPayload: [String: Any] = [:]
                    if let label = anchor.figureLabel { anchorPayload["figure_label"] = label }
                    if let panel = anchor.panelLabel { anchorPayload["panel_label"] = panel }
                    if let passage = anchor.passage { anchorPayload["passage"] = passage }
                    if let page = anchor.pageNumber { anchorPayload["page_number"] = page }
                    if let clock = anchor.momentClock { anchorPayload["at"] = clock }
                    entry["anchor"] = anchorPayload
                    if let label = anchor.figureLabel,
                       let record = figureRecord(labelled: label, in: figures) {
                        if let title = PaperFigureCaptionTitle.title(from: record.caption) {
                            entry["figure_title"] = title
                        }
                        if let panel = anchor.panelLabel,
                           let caption = PaperFigureCaptionTitle.panelCaption(for: panel, in: record.caption) {
                            entry["panel_caption"] = caption
                        }
                    }
                }
                if let beats = step.beats, !beats.isEmpty {
                    entry["beats"] = beats.map { beat -> Any in
                        guard beat.figureLabel != nil || beat.panelLabel != nil else { return beat.text }
                        var pointed: [String: Any] = ["text": beat.text]
                        if let label = beat.figureLabel { pointed["figure_label"] = label }
                        if let panel = beat.panelLabel { pointed["panel_label"] = panel }
                        return pointed
                    }
                }
                if let mention = step.sourceMention { entry["source_mention"] = mention }
                if let brief = step.animationBrief { entry["animation_brief"] = brief }
                if let picture = step.picture {
                    var picturePayload: [String: Any] = [:]
                    if let label = picture.figureLabel { picturePayload["figure_label"] = label }
                    if let panel = picture.panelLabel { picturePayload["panel_label"] = panel }
                    if let brief = picture.brief { picturePayload["brief"] = brief }
                    if let id = picture.imageID { picturePayload["image_id"] = id }
                    entry["picture"] = picturePayload
                }
                if !step.more.isEmpty {
                    entry["more"] = step.more.map { ["label": $0.label, "text": $0.text, "from_paper": $0.fromPaper] as [String: Any] }
                }
                if !step.cites.isEmpty {
                    entry["cites"] = step.cites.map { citation -> [String: Any] in
                        var cited: [String: Any] = ["title": citation.title]
                        if let authors = citation.authors { cited["authors"] = authors }
                        if let year = citation.year { cited["year"] = year }
                        if let venue = citation.venue { cited["venue"] = venue }
                        if let kind = citation.kind { cited["kind"] = kind.rawValue }
                        if let doi = citation.doi { cited["doi"] = doi }
                        if let url = citation.url { cited["url"] = url }
                        if let held = citedSourceIDs[citation.identityKey] {
                            cited["in_library"] = true
                            cited["source_id"] = held
                        } else {
                            cited["in_library"] = false
                        }
                        return cited
                    }
                }
                if let quiz = step.quiz {
                    var quizPayload: [String: Any] = [
                        "kind": quiz.kind.rawValue,
                        "question": quiz.question,
                        "answer": quiz.answer,
                        "key_points": quiz.keyPoints,
                    ]
                    if let target = quiz.targetPanel { quizPayload["target_panel"] = target }
                    entry["quiz"] = quizPayload
                }
                return entry
            }
        }
        return payload
    }

    /// The figure a step's label names — the Reader's own lookup.
    static func figureRecord(labelled label: String, in figures: [PaperFigureRecord]) -> PaperFigureRecord? {
        PaperWalkthroughGeneratorService.figureRecord(labelled: label, in: figures)
    }

    /// The id a raw step carries, or its place in the list.
    static func stepID(_ raw: [String: Any], position: Int) -> String {
        ((raw["id"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "step-\(position)"
    }

    /// A step's `cites` as the validator takes them. An author list passed
    /// as an array is joined with semicolons, a year as a number is its
    /// digits, and a library id — `source_id`, or a `foreverlm://source/`
    /// link as `url` — is checked against this library here, where the
    /// library is: one it does not hold is dropped with a warning and the
    /// work kept by its DOI, address and title.
    func walkthroughCitations(
        _ rawValue: Any?,
        stepPosition position: Int,
        warnings: inout [String]
    ) throws -> [PaperWalkthroughCitation] {
        guard let rawCitations = rawValue as? [[String: Any]], !rawCitations.isEmpty else { return [] }
        let store = try knowledgeStore()
        var citations: [PaperWalkthroughCitation] = []
        for raw in rawCitations {
            func text(_ key: String) -> String? {
                if let value = raw[key] as? String { return Self.trimmedOrNil(value) }
                if let value = raw[key] as? Int { return String(value) }
                if let values = raw[key] as? [String] {
                    return Self.trimmedOrNil(values.compactMap { Self.trimmedOrNil($0) }.joined(separator: "; "))
                }
                return nil
            }
            var kind: PaperWalkthroughCitation.Kind?
            if let name = text("kind") {
                kind = PaperWalkthroughCitation.Kind(rawValue: name.lowercased())
                if kind == nil {
                    warnings.append("Step \(position) cites a work of kind \(name); kind is one of \(PaperWalkthroughCitation.Kind.allCases.map(\.rawValue).joined(separator: ", ")), so it was left out.")
                }
            }
            var url = text("url")
            var sourceID = text("source_id")
            let linkPrefix = "foreverlm://source/"
            if let link = url, link.lowercased().hasPrefix(linkPrefix) {
                sourceID = sourceID ?? String(link.dropFirst(linkPrefix.count)).components(separatedBy: CharacterSet(charactersIn: "?#/")).first
                url = nil
            }
            if let given = sourceID {
                if let held = try store.resolveSourceID(forLinkToken: given) {
                    sourceID = held
                } else {
                    warnings.append("Step \(position) cites source_id \(given), which this library does not hold; the work is kept by its DOI, address and title.")
                    sourceID = nil
                }
            }
            citations.append(PaperWalkthroughCitation(
                title: text("title") ?? "",
                authors: text("authors"),
                year: text("year"),
                venue: text("venue"),
                kind: kind,
                doi: text("doi"),
                url: url,
                sourceID: sourceID
            ))
        }
        return citations
    }

    /// The library source each cited work of `walkthrough` is, keyed by the
    /// citation's `identityKey`: the id the author gave while the library
    /// still holds it, else the DOI or address matched the way a Direction's
    /// evidence is (`KnowledgeStore.librarySourceID(for:)`). A source outside
    /// the knowledge boundary is left out.
    func walkthroughCitedSourceIDs(_ walkthrough: PaperWalkthrough) throws -> [String: String] {
        let citations = walkthrough.steps.flatMap(\.cites)
        guard !citations.isEmpty else { return [:] }
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var held: [String: String] = [:]
        for citation in citations where held[citation.identityKey] == nil {
            var match: String?
            if let id = citation.sourceID, try store.resolveSourceID(forLinkToken: id) == id { match = id }
            if match == nil, citation.doi != nil || citation.url != nil {
                match = try store.librarySourceID(for: DirectionEvidence(
                    citation: citation.title,
                    title: citation.title,
                    url: citation.url,
                    doi: citation.doi,
                    finding: ""
                ))
            }
            if let match, !excluded.contains(match) { held[citation.identityKey] = match }
        }
        return held
    }

    private static func walkthroughInteger(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
#endif
