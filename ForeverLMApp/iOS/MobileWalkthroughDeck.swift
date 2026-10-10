import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

/// The phone's projection of a source's walkthrough (`PaperWalkthrough` on
/// the Mac), read as a deck of cards: one card a point, flipped through by
/// swiping, each showing the figure or panel it is about above its one
/// sentence, and a question as a card of its own (`cards`).
///
/// The record rides the encrypted Source payload as `paperWalkthrough`, and
/// the Mac publishes it only while it matches the source's current text
/// (`KnowledgeStore.loadPaperWalkthrough`), so a payload that carries one
/// carries a walk the phone can show. Like `MobileCloudSourceReviewGuide`
/// this mirrors only what the cards draw; everything else in the record —
/// who wrote it, the animation briefs, animations by reference — is ignored,
/// and a new field the Mac adds decodes to nothing here.
struct MobileWalkthroughDeck: Decodable, Equatable, Sendable {
    /// Mirrors `PaperWalkthrough.currentVersion` on the Mac.
    static let supportedVersion = 1

    struct Step: Decodable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case explain
            case figure
            case quiz

            var label: String {
                switch self {
                case .explain: return "Explanation"
                case .figure: return "Figure"
                case .quiz: return "Question"
                }
            }

            var symbolName: String {
                switch self {
                case .explain: return "text.alignleft"
                case .figure: return "chart.xyaxis.line"
                case .quiz: return "questionmark.circle"
                }
            }
        }

        /// The step's id in the record, which the chat's step line names
        /// (`WalkthroughStepTurn.Marker.stepID`).
        let id: String
        let kind: Kind
        let title: String
        /// The step's points, one a card: its written beats, each a short
        /// sentence that may name the panel it is about, or its body's
        /// paragraphs on a record written before beats.
        let beats: [Point]
        /// The points' words alone.
        var points: [String] { beats.map(\.text) }
        let figureLabel: String?
        let panelLabel: String?
        /// The authors' words the step quotes, on an `explain` step whose
        /// point is in them.
        let passage: String?
        /// The sentence of the paper that cites the step's panel.
        let sourceMention: String?
        /// A complete HTML document, shown under
        /// `PaperWalkthroughAnimationDocument`'s policy.
        let animationHTML: String?
        /// Whether the step shows a saved animation by reference; the
        /// reference itself is read from `record`.
        let hasAnimationReference: Bool
        /// A figure the step's point cards show without the step pointing
        /// at it (`PaperWalkthroughPicture` on the Mac).
        let pictureFigureLabel: String?
        let picturePanelLabel: String?
        /// Or the picture drawn for the step, by its image-store id: the
        /// Source record carries the file beside the walk
        /// (`WalkthroughPicturePackageFormat`), and the phone reads it from
        /// there (`MobileSourceFileStore.walkthroughPicture`). Nil when the
        /// step's picture is a figure, as on the Mac.
        let pictureImageID: String?
        var hasAnimation: Bool { animationHTML != nil || hasAnimationReference }
        let question: String?
        /// The reference answer, shown when the learner turns the card over.
        let answer: String?
        let keyPoints: [String]
        /// How the question is asked (`PaperWalkthroughQuiz.Kind` on the
        /// Mac): a kind this build does not know reads as the plain question.
        let quizKind: QuizKind
        /// Find it: the panel letter that answers.
        let targetPanel: String?
        /// Say more chips: context offered under the point, never pushed.
        let more: [More]
        /// The works the step's point rests on (`PaperWalkthroughCitation`),
        /// shown under its point cards.
        let cites: [PaperWalkthroughCitation]

        enum QuizKind: String, Sendable {
            case recall
            case thinkFirst = "think_first"
            case predict
            case find

            var label: String {
                switch self {
                case .recall: return "Question"
                case .thinkFirst: return "Think first"
                case .predict: return "Predict"
                case .find: return "Find it"
                }
            }
        }

        struct More: Decodable, Equatable, Sendable {
            let label: String
            let text: String
            let fromPaper: Bool

            init(label: String, text: String, fromPaper: Bool) {
                self.label = label
                self.text = text
                self.fromPaper = fromPaper
            }

            private enum CodingKeys: String, CodingKey {
                case label, text
                case fromPaper = "from_paper"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
                text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
                fromPaper = (try? container.decodeIfPresent(Bool.self, forKey: .fromPaper)) ?? false
            }
        }

        /// "Figure 2b", "Figure 3 DESIGN", or nil for a step that points at
        /// no figure.
        var figureDisplayLabel: String? {
            guard let figureLabel else { return nil }
            return PaperWalkthroughValidation.figurePanelLabel(figureLabel, panel: panelLabel)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case kind
            case title
            case body
            case beats
            case anchor
            case sourceMention = "source_mention"
            case animationHTML = "animation_html"
            case animationReference = "animation_ref"
            case picture
            case quiz
            case more
            case cites
        }

        private enum AnchorKeys: String, CodingKey {
            case figureLabel = "figure_label"
            case panelLabel = "panel_label"
            case passage
            /// A picture's only: its drawn picture's id.
            case imageID = "image_id"
        }

        private enum QuizKeys: String, CodingKey {
            case question
            case answer
            case keyPoints = "key_points"
            case kind
            case targetPanel = "target_panel"
        }

        /// One point of a step, as its card says it. A beat is a bare string,
        /// or `{"text", "figure_label", "panel_label"}` when it points at a
        /// panel of its own, and the card's figure follows it there.
        struct Point: Decodable, Equatable, Sendable {
            let text: String
            let figureLabel: String?
            let panelLabel: String?

            init(text: String, figureLabel: String? = nil, panelLabel: String? = nil) {
                self.text = text
                self.figureLabel = figureLabel
                self.panelLabel = panelLabel
            }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                    self.text = text
                    figureLabel = nil
                    panelLabel = nil
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
                figureLabel = Step.cleaned(try container.decodeIfPresent(String.self, forKey: .figureLabel))
                panelLabel = Step.cleaned(try container.decodeIfPresent(String.self, forKey: .panelLabel))
            }

            private enum CodingKeys: String, CodingKey {
                case text
                case figureLabel = "figure_label"
                case panelLabel = "panel_label"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
            kind = Kind(rawValue: rawKind) ?? .explain
            title = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .title)) ?? ""
            let written = (try container.decodeIfPresent([Point].self, forKey: .beats) ?? [])
                .compactMap { beat -> Point? in
                    guard let text = Self.cleaned(beat.text) else { return nil }
                    return Point(text: text, figureLabel: beat.figureLabel, panelLabel: beat.panelLabel)
                }
            beats = written.isEmpty
                ? Self.paragraphs(of: try container.decodeIfPresent(String.self, forKey: .body) ?? "").map { Point(text: $0) }
                : written
            sourceMention = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .sourceMention))
            animationHTML = Self.cleaned(try container.decodeIfPresent(String.self, forKey: .animationHTML))
            hasAnimationReference = container.contains(.animationReference)
                && (try? container.decodeNil(forKey: .animationReference)) == false
            if container.contains(.picture), (try? container.decodeNil(forKey: .picture)) == false,
               let picture = try? container.nestedContainer(keyedBy: AnchorKeys.self, forKey: .picture) {
                pictureFigureLabel = Self.cleaned(try? picture.decodeIfPresent(String.self, forKey: .figureLabel))
                picturePanelLabel = pictureFigureLabel == nil
                    ? nil
                    : Self.cleaned(try? picture.decodeIfPresent(String.self, forKey: .panelLabel))
                pictureImageID = pictureFigureLabel == nil
                    ? Self.imageID(Self.cleaned(try? picture.decodeIfPresent(String.self, forKey: .imageID)))
                    : nil
            } else {
                pictureFigureLabel = nil
                picturePanelLabel = nil
                pictureImageID = nil
            }

            if container.contains(.anchor), (try? container.decodeNil(forKey: .anchor)) == false {
                let anchor = try container.nestedContainer(keyedBy: AnchorKeys.self, forKey: .anchor)
                figureLabel = Self.cleaned(try anchor.decodeIfPresent(String.self, forKey: .figureLabel))
                panelLabel = figureLabel == nil
                    ? nil
                    : Self.cleaned(try anchor.decodeIfPresent(String.self, forKey: .panelLabel))
                passage = Self.cleaned(try anchor.decodeIfPresent(String.self, forKey: .passage))
            } else {
                figureLabel = nil
                panelLabel = nil
                passage = nil
            }

            if container.contains(.quiz), (try? container.decodeNil(forKey: .quiz)) == false {
                let quiz = try container.nestedContainer(keyedBy: QuizKeys.self, forKey: .quiz)
                question = Self.cleaned(try quiz.decodeIfPresent(String.self, forKey: .question))
                answer = Self.cleaned(try quiz.decodeIfPresent(String.self, forKey: .answer))
                keyPoints = (try quiz.decodeIfPresent([String].self, forKey: .keyPoints) ?? [])
                    .compactMap { Self.cleaned($0) }
                let rawQuizKind = Self.cleaned(try? quiz.decodeIfPresent(String.self, forKey: .kind)) ?? "recall"
                quizKind = QuizKind(rawValue: rawQuizKind) ?? .recall
                targetPanel = quizKind == .find ? Self.cleaned(try? quiz.decodeIfPresent(String.self, forKey: .targetPanel)) : nil
            } else {
                question = nil
                answer = nil
                keyPoints = []
                quizKind = .recall
                targetPanel = nil
            }
            more = ((try? container.decodeIfPresent([More].self, forKey: .more)) ?? [])
                .compactMap { chip in
                    guard let label = Self.cleaned(chip.label), let text = Self.cleaned(chip.text) else { return nil }
                    return More(label: label, text: text, fromPaper: chip.fromPaper)
                }
            cites = ((try? container.decodeIfPresent([PaperWalkthroughCitation].self, forKey: .cites)) ?? [])
                .filter { Self.cleaned($0.title) != nil }
        }

        static func cleaned(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }

        /// An image-store id as the Mac's store names a file (lower-case hex
        /// and dashes, 8 to 64 characters: `GeneratedImageReference.isValidID`),
        /// or nil.
        static func imageID(_ value: String?) -> String? {
            guard let id = value?.lowercased(), (8...64).contains(id.count),
                  id.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) || $0 == "-" }) else { return nil }
            return id
        }

        /// The body's paragraphs, which the Mac writes separated by blank lines.
        static func paragraphs(of body: String) -> [String] {
            var paragraphs: [String] = []
            var current: [String] = []
            func flush() {
                if let paragraph = cleaned(current.joined(separator: " ")) { paragraphs.append(paragraph) }
                current.removeAll()
            }
            for raw in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush() } else { current.append(line) }
            }
            flush()
            return paragraphs
        }
    }

    /// One card of the deck (product owner, 2026-09-23: "one point at a time
    /// interspersed with some questions"): a point of a step, or the step's
    /// question. The Mac deals the same cards from the same record
    /// (`PaperWalkthroughStep.playableBeats`), so a card counted here is the
    /// card counted there.
    struct Card: Identifiable, Equatable, Sendable {
        enum Face: Equatable, Sendable {
            /// One sentence of the step, with the figure and panel it is
            /// about when it names one of its own.
            case point(Step.Point)
            /// The step's question, with the reminder its writer gave it.
            case question(String, context: String?)
            /// A chapter's close: the claim the learner can now say, under
            /// the chapter's title.
            case recap(claim: String, chapterTitle: String)
            /// The step's animation, alone on its card.
            case animation
        }

        let id: String
        let stepIndex: Int
        /// Which of the step's cards this is, zero-based, and how many the
        /// step has.
        let indexInStep: Int
        let countInStep: Int
        let face: Face

        var isLastOfStep: Bool { indexInStep == countInStep - 1 }
        var isQuestion: Bool {
            if case .question = face { return true }
            return false
        }
        var isRecap: Bool {
            if case .recap = face { return true }
            return false
        }
        var isAnimation: Bool {
            if case .animation = face { return true }
            return false
        }
    }

    /// One claim of the source and the steps that teach it
    /// (`PaperWalkthroughChapter` on the Mac).
    struct Chapter: Decodable, Equatable, Sendable {
        let id: String
        let title: String
        let claim: String
        let stepIDs: [String]

        init(id: String, title: String, claim: String, stepIDs: [String]) {
            self.id = id
            self.title = title
            self.claim = claim
            self.stepIDs = stepIDs
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, claim
            case stepIDs = "step_ids"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = Step.cleaned(try container.decodeIfPresent(String.self, forKey: .title)) ?? ""
            claim = Step.cleaned(try container.decodeIfPresent(String.self, forKey: .claim)) ?? ""
            stepIDs = try container.decodeIfPresent([String].self, forKey: .stepIDs) ?? []
        }
    }

    let title: String
    let steps: [Step]
    /// The chapters, when the record has them; nil plays as one chapter.
    let chapters: [Chapter]?
    /// Whether the record walks a saved animation rather than a source
    /// (`PaperWalkthrough.Subject`): its steps deal no animation card, since
    /// the animation is the walk's page.
    var isAnimationWalk = false
    /// The whole record the deck was read from, when this phone could read
    /// it as the Mac's own type: what the card's chat composes its step
    /// turns and grading briefs from (`WalkthroughStepComposer`).
    var record: PaperWalkthrough?

    /// The chapter a step is in, by the step's id.
    func chapter(ofStep stepID: String) -> Chapter? {
        chapters?.first { $0.stepIDs.contains(stepID) }
    }

    /// The deck as it is dealt, as the Mac deals it
    /// (`PaperWalkthrough.playableBeats(of:)`): a card a point, the step's
    /// animation on a card of its own, the question last — or, for a
    /// question step, the question alone with its reminder above it, then
    /// the animation — and, after the last step of a chapter with a claim,
    /// the chapter's recap. A step with no words still takes one card, its
    /// title.
    var cards: [Card] {
        var cards: [Card] = []
        for (stepIndex, step) in steps.enumerated() {
            var faces: [Card.Face] = []
            if step.kind == .quiz, let question = step.question {
                let context = step.points.joined(separator: " ")
                faces = [.question(question, context: context.isEmpty ? nil : context)]
            } else {
                faces = step.beats.map { .point($0) }
                if faces.isEmpty { faces = [.point(Step.Point(text: step.title))] }
                if step.hasAnimation, !isAnimationWalk { faces.append(.animation) }
                if let question = step.question { faces.append(.question(question, context: nil)) }
            }
            if step.kind == .quiz, step.question != nil, step.hasAnimation, !isAnimationWalk { faces.append(.animation) }
            if let chapter = chapter(ofStep: step.id), chapter.stepIDs.last == step.id, !chapter.claim.isEmpty {
                faces.append(.recap(claim: chapter.claim, chapterTitle: chapter.title))
            }
            for (index, face) in faces.enumerated() {
                cards.append(Card(
                    id: "\(step.id)#\(index)",
                    stepIndex: stepIndex,
                    indexInStep: index,
                    countInStep: faces.count,
                    face: face
                ))
            }
        }
        return cards
    }

    /// How many cards point at a figure: one step's worth each, since a
    /// figure step's cards all carry its figure.
    var figureStepCount: Int { steps.filter { $0.figureLabel != nil }.count }
    var questionCount: Int { steps.filter { $0.question != nil }.count }

    private enum CodingKeys: String, CodingKey {
        case version
        case title
        case steps
        case chapters
        case subject
    }

    private struct UnsupportedVersion: Error {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.supportedVersion else {
            throw UnsupportedVersion()
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        steps = try container.decode([Step].self, forKey: .steps)
        let stepIDs = Set(steps.map(\.id))
        let decodedChapters = ((try? container.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? nil)?
            .map { Chapter(id: $0.id, title: $0.title, claim: $0.claim, stepIDs: $0.stepIDs.filter { stepIDs.contains($0) }) }
            .filter { !$0.stepIDs.isEmpty }
        chapters = (decodedChapters?.isEmpty == false) ? decodedChapters : nil
        isAnimationWalk = (try? container.decodeIfPresent(String.self, forKey: .subject)) == "animation"
    }

    /// What a step's point cards show when the step points at no figure of
    /// its own: a figure of the source, or a picture drawn for the step.
    enum Picture: Equatable, Sendable {
        case figure(label: String, panel: String?)
        case drawn(imageID: String)
    }

    /// The picture a step's point cards show when the step points at none:
    /// its own picture, else the picture of the nearest step before it in
    /// its chapter that shows one, else of the nearest after it — the Mac's
    /// `PaperWalkthrough.cardPicture(of:)`, drawn pictures included.
    func picture(ofStepAt index: Int) -> Picture? {
        guard !isAnimationWalk, steps.indices.contains(index) else { return nil }
        let step = steps[index]
        guard step.figureLabel == nil else { return nil }
        if let own = Self.ownPicture(of: step) { return own }
        let neighbours: [Step]
        if let chapter = chapter(ofStep: step.id) {
            let ids = Set(chapter.stepIDs)
            neighbours = steps.filter { ids.contains($0.id) }
        } else {
            neighbours = steps
        }
        guard let position = neighbours.firstIndex(where: { $0.id == step.id }) else { return nil }
        func shown(by other: Step) -> Picture? {
            if let label = other.figureLabel { return .figure(label: label, panel: other.panelLabel) }
            return Self.ownPicture(of: other)
        }
        for earlier in neighbours[..<position].reversed() {
            if let picture = shown(by: earlier) { return picture }
        }
        for later in neighbours[(position + 1)...] {
            if let picture = shown(by: later) { return picture }
        }
        return nil
    }

    /// The drawn picture `picture(ofStepAt:)` shows, by its image-store id,
    /// when it is one.
    func drawnPictureID(ofStepAt index: Int) -> String? {
        guard case .drawn(let id)? = picture(ofStepAt: index) else { return nil }
        return id
    }

    /// The figure `picture(ofStepAt:)` shows, when it is a figure.
    func pictureFigure(ofStepAt index: Int) -> (label: String, panel: String?)? {
        guard case .figure(let label, let panel)? = picture(ofStepAt: index) else { return nil }
        return (label, panel)
    }

    /// A step's own picture other than the figure it outlines.
    private static func ownPicture(of step: Step) -> Picture? {
        if let label = step.pictureFigureLabel { return .figure(label: label, panel: step.picturePanelLabel) }
        if let id = step.pictureImageID { return .drawn(imageID: id) }
        return nil
    }

    /// The panels a Find it card offers, in the order the Mac's analysis
    /// listed them, each once: a lettered panel as its letter, lower case
    /// ("b"), a named one as the figure prints it ("DESIGN"). Two panels are
    /// one only when the Mac's validator says so
    /// (`PaperWalkthroughValidation.panelKey`).
    static func panelLetters(of match: FigureMatch?) -> [String] {
        guard let match else { return [] }
        var seen = Set<String>()
        return (match.figure.analysis?.panels ?? []).compactMap { panel -> String? in
            guard let key = PaperWalkthroughValidation.panelKey(panel.label), seen.insert(key).inserted else { return nil }
            return PaperWalkthroughValidation.panelLetter(panel.label)?.lowercased()
                ?? PaperWalkthroughValidation.panelDisplayName(panel.label)
        }
    }

    /// The figure a card shows: the synced figure row, the panel the Mac's
    /// analysis measured when it measured the step's (otherwise the
    /// renderer finds the panel on the page by its printed letter), and
    /// whether other figures share the page, which the renderer's crop
    /// search needs to know.
    struct FigureMatch {
        let figure: SyncedPaperFigure
        let panel: PaperFigurePanel?
        let sharesPage: Bool
    }

    /// The figure a step points at, from the figures synced with the same
    /// source. Labels are compared the way the Mac's validator compares them
    /// ("Fig. 2" is "Figure 2"), since the index and the anchor may print
    /// them differently.
    static func figure(for step: Step, in figures: [SyncedPaperFigure]) -> FigureMatch? {
        guard let label = step.figureLabel else { return nil }
        return figure(labelled: label, panel: step.panelLabel, in: figures)
    }

    /// The figure a card shows: the panel its point names when it names one
    /// (a card about panel d of the step's figure shows panel d), otherwise
    /// the step's own figure and panel.
    static func figure(for card: Card, of step: Step, in figures: [SyncedPaperFigure]) -> FigureMatch? {
        if case .recap = card.face { return nil }
        guard case .point(let point) = card.face else { return figure(for: step, in: figures) }
        let label = point.figureLabel ?? step.figureLabel
        guard let label else { return nil }
        let panel = point.figureLabel == nil
            ? (point.panelLabel ?? step.panelLabel)
            : point.panelLabel
        return figure(labelled: label, panel: panel, in: figures)
    }

    /// The panel a card's figure is cut to: the panel its point names, else
    /// the step's own; nil for a whole figure. A point naming another figure
    /// names its own panel or none.
    static func panelLabel(for card: Card, of step: Step) -> String? {
        guard case .point(let point) = card.face else { return step.panelLabel }
        if point.figureLabel != nil { return point.panelLabel }
        return point.panelLabel ?? step.panelLabel
    }

    /// "Figure 2d" for a card whose point names panel d; the step's own label
    /// otherwise; nil for a card that points at no figure.
    static func figureDisplayLabel(for card: Card, of step: Step) -> String? {
        guard case .point(let point) = card.face else { return step.figureDisplayLabel }
        if let figure = point.figureLabel {
            return PaperWalkthroughValidation.figurePanelLabel(figure, panel: point.panelLabel)
        }
        guard let figure = step.figureLabel else { return nil }
        return PaperWalkthroughValidation.figurePanelLabel(figure, panel: point.panelLabel ?? step.panelLabel)
    }

    static func figure(labelled label: String, panel panelLabel: String?, in figures: [SyncedPaperFigure]) -> FigureMatch? {
        let needle = canonicalFigureLabel(label)
        // A figure whose caption runs onto the next page ("See next page for
        // caption") has a second row under the same label; the figure itself
        // is on the earlier page, and the row the analysis measured wins.
        let candidates = figures
            .filter { canonicalFigureLabel($0.figureLabel) == needle }
            .sorted { $0.pageIndex < $1.pageIndex }
        guard let figure = candidates.first(where: { $0.analysis?.figureRect?.isValid == true })
            ?? candidates.first else {
            return nil
        }
        let sharesPage = Set(
            figures.filter { $0.pageIndex == figure.pageIndex }.map { canonicalFigureLabel($0.figureLabel) }
        ).count > 1
        let panel = panelLabel.flatMap { wanted -> PaperFigurePanel? in
            figure.analysis?.panels.first {
                PaperWalkthroughValidation.samePanel($0.label, wanted) && $0.rect?.isValid == true
            }
        }
        return FigureMatch(figure: figure, panel: panel, sharesPage: sharesPage)
    }

    static func canonicalFigureLabel(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "fig.", with: "figure")
            .replacingOccurrences(of: "fig ", with: "figure ")
            .replacingOccurrences(of: "figure", with: "figure ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Reads the walkthrough out of a Source payload: nil when the payload has
/// none, when its version is one this build does not know, or when it has no
/// steps, so the reader offers the deck only when there is one to flip.
enum MobileWalkthroughPayloadParser {
    private struct Envelope: Decodable {
        let paperWalkthrough: MobileWalkthroughDeck?

        private enum CodingKeys: String, CodingKey { case paperWalkthrough }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A record this build cannot read costs the deck, never the
            // source the payload describes.
            paperWalkthrough = try? container.decodeIfPresent(MobileWalkthroughDeck.self, forKey: .paperWalkthrough)
        }
    }

    /// The deck of a record this phone holds itself — one it has just
    /// written — read through the same decoder as a synced one.
    static func deck(from walkthrough: PaperWalkthrough) -> MobileWalkthroughDeck? {
        guard let data = try? JSONEncoder().encode(walkthrough),
              var deck = try? JSONDecoder().decode(MobileWalkthroughDeck.self, from: data),
              !deck.steps.isEmpty else {
            return nil
        }
        deck.record = walkthrough
        return deck
    }

    private struct RecordEnvelope: Decodable {
        let paperWalkthrough: PaperWalkthrough?

        private enum CodingKeys: String, CodingKey { case paperWalkthrough }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paperWalkthrough = try? container.decodeIfPresent(PaperWalkthrough.self, forKey: .paperWalkthrough)
        }
    }

    static func deck(from payloadData: Data) -> MobileWalkthroughDeck? {
        let decoder = JSONDecoder()
        guard var deck = try? decoder.decode(Envelope.self, from: payloadData).paperWalkthrough,
              !deck.steps.isEmpty else {
            return nil
        }
        deck.record = try? decoder.decode(RecordEnvelope.self, from: payloadData).paperWalkthrough
        return deck
    }
}

// MARK: - Where the learner was

/// The card the learner left a source's deck on, so reopening it picks up
/// there. A convenience of this phone alone: it is not synced, and a deck
/// left on its last card opens at the cover again.
enum MobileWalkthroughDeckPosition {
    private static func key(_ sourceID: String) -> String { "walkthroughDeck.position.\(sourceID)" }

    static func restored(sourceID: String, cardCount: Int, defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: key(sourceID))
        guard saved > 0, saved < cardCount - 1 else { return 0 }
        return saved
    }

    static func save(_ position: Int, sourceID: String, cardCount: Int, defaults: UserDefaults = .standard) {
        if position <= 0 || position >= cardCount - 1 {
            defaults.removeObject(forKey: key(sourceID))
        } else {
            defaults.set(position, forKey: key(sourceID))
        }
    }
}
