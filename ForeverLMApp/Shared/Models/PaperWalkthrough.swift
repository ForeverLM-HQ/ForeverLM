import Foundation

/// A guided walk through one source, read inside the Reader.
///
/// The Reader shows the walkthrough one step at a time beside the source: each
/// step scrolls to what it talks about — a figure, one of its panels, a
/// passage — explains it, and may play a small animation drawn as code or ask
/// a question. It is the in-Reader form of the "figure companion" sites
/// (walkthrough-design.md): the source stays the thing on screen and the
/// explanation moves over it, instead of being redrawn on a page of its own.
///
/// Written for papers and keeping the name; since 2026-09-19 a book chapter
/// and an article are walked through too (`PaperWalkthroughSubject`). A source
/// shown as a PDF — a paper, a chapter split from a PDF — anchors steps to
/// figures and passages; one shown as text or a web page — an article, an
/// EPUB chapter — anchors them to passages alone, which the Reader scrolls to
/// and flashes.
///
/// Stored per source in `source_walkthroughs` and synced inside the encrypted
/// Source payload, as the review guide is; whoever writes it — the app's own
/// writer, or Claude and Codex through `save_walkthrough` — saves this one
/// record.
/// Whether a source's walkthrough row still describes the source: `ok` when
/// it was written against the text the source carries now, `stale` when the
/// text moved under it (or the record predates the current version). A source
/// with no row has no status.
enum PaperWalkthroughStatus: String, Sendable {
    case ok
    case stale
}

/// A source's walkthrough as a notebook's Studio lists it (product owner,
/// 2026-09-23: "walkthroughs need to be dedicated artifacts … docs, sites,
/// videos, animations, images; walkthroughs need to be additional there"):
/// what the card says without the steps' words. The record itself stays
/// with its source — one a source, synced in the Source payload the phone
/// reads — so listing it here adds no table and no CloudKit field.
struct PaperWalkthroughSummary: Equatable, Sendable, Identifiable {
    var sourceID: String
    var title: String
    var stepCount: Int
    var chapterCount: Int
    /// One a point, one a question, one a chapter's recap (`PaperWalkthrough.cardCount`).
    var cardCount: Int
    var questionCount: Int
    var figureStepCount: Int
    var animationCount: Int
    var generatedAt: Date
    var author: PaperWalkthrough.Author
    /// `ok` while the walk was written against the text the source carries
    /// now; `stale` once that text moved, when the Reader offers Write
    /// Walkthrough Again.
    var status: PaperWalkthroughStatus

    var id: String { sourceID }
}

/// Where the learner is in a walk and how the walk's questions went, kept
/// for the walk itself rather than read back out of a chat
/// (walkthrough-design.md, "2026-09-23, night: the walk leaves the chat").
/// One a walk, keyed by its subject: a source id, or an animation's artifact
/// id. Per learner, so it never enters a team record; synced as the
/// `WalkthroughProgress` CloudKit record so every Mac resumes on the same
/// card.
struct WalkthroughProgress: Codable, Equatable, Sendable {
    /// How a question card ended. Stored as its raw string, so an outcome a
    /// later build adds reads as none rather than failing the record.
    enum Outcome: String, Sendable {
        case remembered
        case forgot
        /// Answered in the learner's own words in the walk's chat, where the
        /// tutor's reply is the grade.
        case answered
    }

    var subjectID: String
    /// The step the learner is on; nil before the first card is dealt.
    var currentStepID: String?
    /// How many of each step's cards have been dealt, by step id.
    var revealedBeats: [String: Int]
    /// The steps dealt at least once, in the order they were first dealt.
    var playedStepIDs: [String]
    /// Raw `Outcome` values, by step id.
    var outcomeValues: [String: String]
    /// The chat the learner's questions about the walk went to; nil until
    /// one was asked.
    var chatSessionID: String?
    var updatedAt: Date

    init(
        subjectID: String,
        currentStepID: String? = nil,
        revealedBeats: [String: Int] = [:],
        playedStepIDs: [String] = [],
        outcomes: [String: Outcome] = [:],
        chatSessionID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.subjectID = subjectID
        self.currentStepID = currentStepID
        self.revealedBeats = revealedBeats
        self.playedStepIDs = playedStepIDs
        self.outcomeValues = outcomes.mapValues(\.rawValue)
        self.chatSessionID = chatSessionID
        self.updatedAt = updatedAt
    }

    var outcomes: [String: Outcome] {
        get { outcomeValues.compactMapValues(Outcome.init(rawValue:)) }
        set { outcomeValues = newValue.mapValues(\.rawValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case subjectID = "subject_id"
        case currentStepID = "current_step_id"
        case revealedBeats = "revealed_beats"
        case playedStepIDs = "played_step_ids"
        case outcomeValues = "outcomes"
        case chatSessionID = "chat_session_id"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjectID = try container.decode(String.self, forKey: .subjectID)
        currentStepID = try container.decodeIfPresent(String.self, forKey: .currentStepID)
        revealedBeats = try container.decodeIfPresent([String: Int].self, forKey: .revealedBeats) ?? [:]
        playedStepIDs = try container.decodeIfPresent([String].self, forKey: .playedStepIDs) ?? []
        outcomeValues = try container.decodeIfPresent([String: String].self, forKey: .outcomeValues) ?? [:]
        chatSessionID = try container.decodeIfPresent(String.self, forKey: .chatSessionID)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// The progress a chat played before this record existed implies: its
    /// step turns, the last of them the step the learner was on. Nil for a
    /// chat that played none of this walk.
    static func seeded(subjectID: String, markers: [WalkthroughStepTurn.Marker], chatSessionID: String?) -> WalkthroughProgress? {
        let own = markers.filter { $0.sourceID == subjectID }
        guard let last = own.last else { return nil }
        var played: [String] = []
        for marker in own where !played.contains(marker.stepID) { played.append(marker.stepID) }
        return WalkthroughProgress(
            subjectID: subjectID,
            currentStepID: last.stepID,
            playedStepIDs: played,
            chatSessionID: chatSessionID
        )
    }
}

struct PaperWalkthrough: Codable, Equatable, Sendable {
    static let currentVersion = 1

    /// What the walk is of. A `source` walk points its steps at a paper's,
    /// chapter's or article's own pages; an `animation` walk (product owner,
    /// 2026-09-20: animations "should not really be stored as sites … it
    /// makes more sense to have it as a walkthrough") is of a saved
    /// animation, and every step shows that animation pinned to one of its
    /// own steps. `sourceID` holds the subject's id either way — a source id
    /// or an artifact id — so the marker, the chat and the storage read one
    /// key; the row lives in `source_walkthroughs` or `artifact_walkthroughs`
    /// by the subject.
    enum Subject: String, Codable, Sendable {
        case source
        case animation
    }

    /// Who wrote the steps.
    enum Author: String, Codable, Sendable {
        /// The app's Walkthrough Writing model, from the paper's text and its
        /// figure index.
        case app
        /// An outside assistant, through the `save_walkthrough` MCP tool.
        case assistant
    }

    var version: Int
    /// The walk's chapters (2026-09-23, from the merged lesson): each one
    /// claim of the source the learner should be able to say by its end,
    /// and the steps that teach it. Nil on a record written before, which
    /// plays as one unnamed chapter; the last step of a chapter with a
    /// claim deals a recap card that says the claim back.
    var chapters: [PaperWalkthroughChapter]?
    /// The subject's id: a source id, or an artifact id for an animation walk.
    var sourceID: String
    /// The SHA-256 of the paper text the steps were written against. A
    /// walkthrough of a text the paper no longer carries is not shown. For an
    /// animation walk, the fingerprint of the animation's address
    /// (`PaperWalkthrough.animationFingerprint`).
    var sourceSHA256: String
    var subject: Subject
    var title: String
    var steps: [PaperWalkthroughStep]
    var generatedAt: Date
    var author: Author

    init(
        sourceID: String,
        sourceSHA256: String,
        subject: Subject = .source,
        title: String,
        steps: [PaperWalkthroughStep],
        chapters: [PaperWalkthroughChapter]? = nil,
        generatedAt: Date = Date(),
        author: Author,
        version: Int = PaperWalkthrough.currentVersion
    ) {
        self.version = version
        self.sourceID = sourceID
        self.sourceSHA256 = sourceSHA256
        self.subject = subject
        self.title = title
        self.steps = steps
        self.chapters = (chapters?.isEmpty == false) ? chapters : nil
        self.generatedAt = generatedAt
        self.author = author
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourceID = "source_id"
        case sourceSHA256 = "source_sha256"
        case subject
        case title
        case steps
        case chapters
        case generatedAt = "generated_at"
        case author
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        // A record written before animation walks names no subject: it is a
        // source walk, which is what every such record was.
        subject = try container.decodeIfPresent(Subject.self, forKey: .subject) ?? .source
        title = try container.decode(String.self, forKey: .title)
        steps = try container.decode([PaperWalkthroughStep].self, forKey: .steps)
        // A record written before chapters has none; a chapter naming no
        // step of this record is dropped rather than shown empty.
        let stepIDs = Set(steps.map(\.id))
        let decodedChapters = ((try? container.decodeIfPresent([PaperWalkthroughChapter].self, forKey: .chapters)) ?? nil)?
            .map { chapter in
                var kept = chapter
                kept.stepIDs = chapter.stepIDs.filter { stepIDs.contains($0) }
                return kept
            }
            .filter { !$0.stepIDs.isEmpty }
        chapters = (decodedChapters?.isEmpty == false) ? decodedChapters : nil
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        author = try container.decode(Author.self, forKey: .author)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        // Absent for a source walk, so a record saved before this key encodes
        // byte for byte as it did.
        if subject != .source { try container.encode(subject, forKey: .subject) }
        try container.encode(title, forKey: .title)
        try container.encode(steps, forKey: .steps)
        if let chapters, !chapters.isEmpty { try container.encode(chapters, forKey: .chapters) }
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(author, forKey: .author)
    }

    /// What an animation walk's `sourceSHA256` holds: the animation's address
    /// digested, so a walk written for one address is not shown against
    /// another (a slug change re-keys the walk; a republish of the same page
    /// does not, since the steps it names are the page's own).
    static func animationFingerprint(linkedURL: String?, artifactID: String) -> String {
        PaperWalkthroughWriting.sha256(linkedURL ?? artifactID)
    }

    var isUsable: Bool {
        version == Self.currentVersion && !steps.isEmpty
    }

    /// Whether a figure step still lacks the authors' sentence about its
    /// panel: true for a record written before 2026-09-21, when
    /// `PaperWalkthroughStep.sourceMention` began to be kept, and for one
    /// whose figure the text never cites (a look that finds nothing is not
    /// stored, so such a record is read again; the read is a sentence split
    /// of the text, once per open).
    var needsSourceMentions: Bool {
        subject == .source && steps.contains { $0.anchor?.figureLabel != nil && $0.sourceMention == nil }
    }

    /// The record with the authors' sentence found for every figure step
    /// that lacks one, from `text`, the source's own words as validation
    /// reads them. A record written before mentions were kept plays with
    /// them from its next open; a step whose figure the text never cites is
    /// left as it was.
    func fillingSourceMentions(from text: String) -> PaperWalkthrough {
        guard needsSourceMentions else { return self }
        var filled = self
        for index in filled.steps.indices {
            let step = filled.steps[index]
            guard step.sourceMention == nil, let label = step.anchor?.figureLabel else { continue }
            filled.steps[index].sourceMention = PaperFigureMention.sentence(
                citing: label,
                panel: step.anchor?.panelLabel,
                in: text
            )
        }
        return filled
    }

    /// How many steps ask a question.
    var quizCount: Int { steps.filter { $0.quiz != nil }.count }

    /// How many steps point at a figure.
    var figureStepCount: Int { steps.filter { $0.anchor?.figureLabel != nil }.count }

    /// How many chapters the walk teaches: the record's, or one.
    var chapterCount: Int { max(1, chapters?.count ?? 1) }

    /// The chapter a step belongs to, by the step's id; nil on a record
    /// with no chapters, or for a step no chapter names.
    func chapterIndex(ofStep stepID: String) -> Int? {
        chapters?.firstIndex { $0.stepIDs.contains(stepID) }
    }

    func chapter(ofStep stepID: String) -> PaperWalkthroughChapter? {
        chapterIndex(ofStep: stepID).flatMap { chapters?[$0] }
    }

    /// The steps a question follows, nearest first: the ones before it in
    /// its chapter (on a record with no chapters, in the walk), where the
    /// point it tests was made — a question is placed right after the point
    /// it asks about. A question step rarely carries a passage of its own,
    /// so its Memory item is grounded in theirs (`SourceMemoryQuestion`).
    func stepsBefore(question stepID: String) -> [PaperWalkthroughStep] {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return [] }
        let earlier = Array(steps[..<index].reversed())
        guard let chapter = chapter(ofStep: stepID) else { return earlier }
        let inChapter = Set(chapter.stepIDs)
        return earlier.filter { inChapter.contains($0.id) }
    }

    /// Whether the step is the last its chapter names, and the chapter has
    /// a claim to say back: the step then deals a recap card last.
    func closesChapter(_ step: PaperWalkthroughStep) -> PaperWalkthroughChapter? {
        guard let chapter = chapter(ofStep: step.id), chapter.stepIDs.last == step.id,
              !chapter.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return chapter
    }

    /// The cards the deck deals for a step, in the walk: the step's own
    /// (`PaperWalkthroughStep.playableBeats`), its animation on a card of
    /// its own, then, on the last step of a chapter with a claim, the recap
    /// card — "You can now say" and the claim (the lesson's chapter recap,
    /// merged 2026-09-23).
    ///
    /// The animation used to ride under the step's last point, beneath the
    /// figure, and was cut off by the card's height cap (product owner,
    /// 2026-09-24: "maybe animations should also always be shown separately
    /// from an image"). Its card comes after the points it illustrates and
    /// before the question that tests them; on a question step, after the
    /// question, since the animation would give a prediction away. A walk of
    /// an animation deals none: that animation is the page beside the chat.
    func playableBeats(of step: PaperWalkthroughStep) -> [WalkthroughBeat] {
        var beats = step.playableBeats
        if subject == .source, step.hasAnimation {
            let card = WalkthroughBeat(kind: .animation, text: step.title)
            if step.kind != .quiz, let question = beats.firstIndex(where: { $0.kind == .question }) {
                beats.insert(card, at: question)
            } else {
                beats.append(card)
            }
        }
        if let chapter = closesChapter(step) {
            beats.append(WalkthroughBeat(kind: .recap, text: chapter.claim, context: chapter.title))
        }
        return beats
    }

    /// How many cards a step takes in this walk, never fewer than one.
    func cardCount(of step: PaperWalkthroughStep) -> Int { max(1, playableBeats(of: step).count) }

    /// How many cards the deck deals for the whole walk: one a point, one a
    /// question, one a chapter's recap.
    var cardCount: Int { steps.reduce(0) { $0 + cardCount(of: $1) } }

    /// The one-based place of a card in the whole deck: the cards of the
    /// steps before `stepIndex`, then `card` (one-based) of that step.
    func cardOrdinal(stepIndex: Int, card: Int) -> Int {
        let before = steps.prefix(max(0, min(stepIndex, steps.count))).reduce(0) { $0 + cardCount(of: $1) }
        return before + max(1, card)
    }

    /// How many steps carry an animation, inline or by reference.
    var animationCount: Int { steps.filter(\.hasAnimation).count }

    /// Steps still waiting for their animation to be drawn.
    var stepsAwaitingAnimation: [PaperWalkthroughStep] {
        steps.filter { !$0.hasAnimation && ($0.animationBrief?.isEmpty == false) }
    }

    /// Steps whose picture has a brief and nothing drawn yet.
    var stepsAwaitingPicture: [PaperWalkthroughStep] {
        steps.filter { step in
            step.anchor?.figureLabel == nil
                && step.picture?.figureLabel == nil
                && step.picture?.imageID == nil
                && step.picture?.brief != nil
        }
    }

    /// The picture a step's cards show above their point: the figure it
    /// outlines; else its own picture — a figure of the source, or the one
    /// drawn for it; else the picture of the nearest step before it in its
    /// chapter that has one, and, for a chapter's opening steps, of the
    /// nearest after it (product owner, 2026-09-24: "multiple cards can obviously
    /// talk about the same image"). A chapter is where the borrowing stops:
    /// its steps teach one claim, so its pictures are about that claim; a
    /// walk without chapters is one. Nil when nothing in the chapter has a
    /// picture — an article whose steps drew none — and on a walk of an
    /// animation, whose picture is the animation beside the chat.
    ///
    /// A step whose brief is not drawn yet borrows too: the brief waits,
    /// and the card is not left bare meanwhile.
    func cardPicture(of step: PaperWalkthroughStep) -> WalkthroughCardPicture? {
        guard subject == .source else { return nil }
        if step.anchor?.figureLabel != nil { return .anchoredFigure }
        if let own = Self.ownPicture(of: step) { return own }
        let neighbours: [PaperWalkthroughStep]
        if let chapter = chapter(ofStep: step.id) {
            let ids = Set(chapter.stepIDs)
            neighbours = steps.filter { ids.contains($0.id) }
        } else {
            neighbours = steps
        }
        guard let position = neighbours.firstIndex(where: { $0.id == step.id }) else { return nil }
        for earlier in neighbours[..<position].reversed() {
            if let picture = Self.sharedPicture(of: earlier) { return picture }
        }
        for later in neighbours[(position + 1)...] {
            if let picture = Self.sharedPicture(of: later) { return picture }
        }
        return nil
    }

    /// A step's own picture other than the figure it outlines.
    private static func ownPicture(of step: PaperWalkthroughStep) -> WalkthroughCardPicture? {
        if let anchor = step.picture?.figureAnchor { return .figure(anchor) }
        if let id = step.picture?.imageID { return .drawn(imageID: id, brief: step.picture?.brief) }
        return nil
    }

    /// What another step's cards lend this one: its outlined figure as a
    /// plain figure (without the passage or the page), or its own picture.
    private static func sharedPicture(of step: PaperWalkthroughStep) -> WalkthroughCardPicture? {
        if let label = step.anchor?.figureLabel {
            return .figure(PaperWalkthroughAnchor(figureLabel: label, panelLabel: step.anchor?.panelLabel, pageNumber: step.anchor?.pageNumber))
        }
        return ownPicture(of: step)
    }

    /// The animations the steps refer to, by id, in step order.
    var referencedAnimationIDs: [String] {
        var seen = Set<String>()
        return steps.compactMap { step in
            guard let id = step.animation?.animationID, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// The drawn pictures the steps name (`PaperWalkthroughPicture.imageID`),
    /// lower-cased, in step order, each once. The Source record carries them
    /// beside the walk (`WalkthroughPicturePackageFormat`), since a picture
    /// lives in the image store of the Mac that drew or saved it.
    var drawnPictureIDs: [String] {
        var seen = Set<String>()
        return steps.compactMap { step in
            guard let id = step.picture?.imageID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

/// One claim of the source and the steps that teach it (2026-09-23, from
/// the merged lesson): the title over its cards' segment, the claim the
/// learner should be able to say by its end — which its recap card says
/// back — and the ids of its steps, in order. Steps stay one flat list on
/// the record, so every reader of `steps` is unchanged.
struct PaperWalkthroughChapter: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var claim: String
    var stepIDs: [String]

    init(id: String, title: String, claim: String, stepIDs: [String]) {
        self.id = id
        self.title = title
        self.claim = claim
        self.stepIDs = stepIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case claim
        case stepIDs = "step_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        claim = try container.decodeIfPresent(String.self, forKey: .claim) ?? ""
        stepIDs = try container.decodeIfPresent([String].self, forKey: .stepIDs) ?? []
    }
}

/// A "Say more": a chip under a card's point, and what it says when pressed
/// (2026-09-23, from the merged lesson). Context offered, never pushed: a
/// term, a method, a why that a newcomer may want and an expert would skip.
struct PaperWalkthroughMore: Codable, Equatable, Sendable {
    var label: String
    var text: String
    /// Whether the words come from the source. Anything else is general
    /// knowledge, and the card labels it so.
    var fromPaper: Bool

    init(label: String, text: String, fromPaper: Bool) {
        self.label = label
        self.text = text
        self.fromPaper = fromPaper
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case text
        case fromPaper = "from_paper"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        fromPaper = (try? container.decodeIfPresent(Bool.self, forKey: .fromPaper)) ?? false
    }
}

/// A work a step cites: the paper, book, article or talk its point rests on,
/// named as the source names it (product owner, 2026-09-30, of a card that read
/// "Alexander Lerchner of Google DeepMind argues…": "if a walkthrough ever
/// cites a paper or article, it would be nice if that source was actually
/// shown there in a nice way"). The step's point cards show it under the
/// point as a source card that opens it — the saved copy when the library
/// holds it, else its page — and the tutor reads it with the step.
///
/// Which record it is stays deterministic: the library id the author gave,
/// then the DOI, then the address, and for a work named with neither, a
/// saved source of exactly that title. The writer and an assistant only copy
/// what the source prints (or, for an assistant, an address it opened); no
/// model decides which record a citation is.
struct PaperWalkthroughCitation: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case paper
        case book
        case article
        case video
        case podcast

        var label: String {
            switch self {
            case .paper: return "Paper"
            case .book: return "Book"
            case .article: return "Article"
            case .video: return "Video"
            case .podcast: return "Podcast"
            }
        }

        /// The glyph a source row of this kind draws (`SourceThumbnail`).
        var symbolName: String {
            switch self {
            case .paper: return "doc.text.magnifyingglass"
            case .book: return "book.closed"
            case .article: return "doc.richtext"
            case .video: return "play.rectangle"
            case .podcast: return "headphones"
            }
        }
    }

    /// The small line over a card's title: "Cited paper", or "Cited work"
    /// when the walk did not say what it is.
    static func eyebrow(kind: Kind?) -> String {
        kind.map { "Cited \($0.label.lowercased())" } ?? "Cited work"
    }

    /// The title in full, as the source or its reference list prints it.
    var title: String
    /// The authors as printed, separated by semicolons — the delimiter paper
    /// metadata stores its author list with.
    var authors: String?
    var year: String?
    /// The journal, publisher, preprint server or site.
    var venue: String?
    var kind: Kind?
    /// `10.x/y`, lower-cased, without a resolver prefix.
    var doi: String?
    /// An http(s) address of the work itself.
    var url: String?
    /// The library source it is, when the author knew it. A hint only: the
    /// card looks again by DOI and address, so a copy the library gained or
    /// lost since is found or passed over.
    var sourceID: String?

    init(
        title: String,
        authors: String? = nil,
        year: String? = nil,
        venue: String? = nil,
        kind: Kind? = nil,
        doi: String? = nil,
        url: String? = nil,
        sourceID: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.kind = kind
        self.doi = doi
        self.url = url
        self.sourceID = sourceID
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case authors
        case year
        case venue
        case kind
        case doi
        case url
        case sourceID = "source_id"
    }

    /// A writer hands a year back as a number as often as a string, and a
    /// kind this build does not know is no kind; neither loses the citation.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        authors = (try? container.decodeIfPresent(String.self, forKey: .authors)) ?? nil
        if let text = try? container.decodeIfPresent(String.self, forKey: .year) {
            year = text
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .year) {
            year = String(number)
        } else {
            year = nil
        }
        venue = (try? container.decodeIfPresent(String.self, forKey: .venue)) ?? nil
        kind = ((try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil)
            .flatMap { Kind(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        doi = (try? container.decodeIfPresent(String.self, forKey: .doi)) ?? nil
        url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
        sourceID = (try? container.decodeIfPresent(String.self, forKey: .sourceID)) ?? nil
    }

    /// What a click opens when the library does not hold the work: its own
    /// page, else its DOI's resolver. Nil for a work named with neither.
    var address: URL? {
        if let url, let parsed = URL(string: url),
           let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
           parsed.host?.isEmpty == false {
            return parsed
        }
        if let doi = Self.normalizedDOI(doi) { return URL(string: "https://doi.org/\(doi)") }
        return nil
    }

    /// The line under the title: the authors shortened as a paper row
    /// shortens them (`StudioArticle.shortAuthorDisplay`: one name, two
    /// joined, the first "et al."), the venue and the year.
    var byline: String? {
        let names = (authors ?? "")
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lead: String?
        switch names.count {
        case 0: lead = nil
        case 1: lead = names[0]
        case 2: lead = "\(names[0]) & \(names[1])"
        default: lead = "\(names[0]) et al."
        }
        let parts = [lead, venue, year].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where a work named with no address is looked up: a Google Scholar
    /// search for its title in quotes and its first author.
    var scholarSearchURL: URL? {
        let firstAuthor = authors?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let query = ["\"\(title)\"", firstAuthor].compactMap { $0 }.joined(separator: " ")
        var components = URLComponents(string: "https://scholar.google.com/scholar")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// One line for the tutor and for a copied citation: "Lerchner A. The
    /// Abstraction Fallacy. 2026. doi:…".
    var referenceLine: String {
        var parts: [String] = []
        if let authors = authors?.trimmingCharacters(in: .whitespacesAndNewlines), !authors.isEmpty {
            parts.append(authors.replacingOccurrences(of: ";", with: ","))
        }
        parts.append(title)
        if let venue = venue?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty { parts.append(venue) }
        if let year = year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty { parts.append(year) }
        if let doi = Self.normalizedDOI(doi) {
            parts.append("doi:\(doi)")
        } else if let address {
            parts.append(address.absoluteString)
        }
        // A part that ends in its own stop ("What Is Life?") takes no second one.
        var line = ""
        for part in parts {
            if !line.isEmpty { line += line.last.map { ".?!".contains($0) } == true ? " " : ". " }
            line += part
        }
        return line
    }

    /// Two citations of one work share this: the DOI, else the address,
    /// else the title folded to its letters and digits.
    var identityKey: String {
        if let doi = Self.normalizedDOI(doi) { return "doi:\(doi)" }
        // With no DOI the address can only be the work's own page.
        if let address { return "url:\(address.absoluteString.lowercased())" }
        return "title:\(Self.foldedTitle(title))"
    }

    /// A DOI as `10.x/y`: resolver prefixes and a `doi:` label stripped,
    /// lower-cased; nil when what is left is not a DOI. The rule
    /// `DirectionEvidence.normalizedDOI` applies, here because this file is
    /// compiled for the phone too.
    static func normalizedDOI(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("10."), value.contains("/") else { return nil }
        return value
    }

    /// A title folded to its lower-cased letters and digits, one space
    /// between words — `VideoCitedPaper.normalizeTitle`'s rule, so a
    /// citation and a source's recorded cited papers compare alike.
    static func foldedTitle(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// One stop on the walk.
struct PaperWalkthroughStep: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// A passage or idea explained; the Reader scrolls to the anchor.
        case explain
        /// A figure or panel; the Reader scrolls to it and outlines it.
        case figure
        /// A question about what was just shown.
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

    var id: String
    var kind: Kind
    var title: String
    /// Plain paragraphs, separated by blank lines. No Markdown headings.
    var body: String
    var anchor: PaperWalkthroughAnchor?
    /// A complete HTML document — inline SVG or Canvas, styles and script —
    /// shown in the step's card and playable enlarged. Nothing loads from the
    /// network and nothing persists.
    var animationHTML: String?
    /// What the animation should show, in the writer's words. Kept so the
    /// drawing pass can run after the steps are already usable, and so a
    /// redraw knows what was asked.
    var animationBrief: String?
    /// A saved animation the step shows instead of carrying its own HTML: the
    /// animation's page, pinned to one of its steps under given conditions
    /// (`WalkthroughAnimationReference`). One drawing serves the whole walk,
    /// with no size limit and nothing duplicated per step.
    var animation: WalkthroughAnimationReference?
    var quiz: PaperWalkthroughQuiz?
    /// The sentence of the source's own text that cites the panel (or, when
    /// none does, the figure) the step outlines — "Intracellular Na rose
    /// within minutes of ouabain (Fig. 1a)" — so the chat repeats the
    /// authors' words under the step's own (product owner, 2026-09-21: "when it
    /// highlights e.g. figure 1a; perhaps it would be helpful to also repeat
    /// the sentence in the paper where they explain figure 1a"). Found by
    /// `PaperFigureMention` when the record is validated, never written by
    /// the writer; nil for a step without a figure anchor and for a figure
    /// the text never cites.
    var sourceMention: String?
    /// The step cut into what one press of Next shows: one short sentence
    /// each, in the order the learner meets them — for a figure step, where
    /// to look, the axes, the legend, what the data do, and last the
    /// takeaway (product owner, 2026-09-22: "one simple point at a time … can even
    /// be multiple clicks"). Written by the writer or an outside author; nil
    /// on a record written before, which `playableBeats` cuts from `body`.
    /// A beat may name the panel it is about, and the Reader's outline moves
    /// there when it is shown (product owner, 2026-09-22: "these beats should also
    /// be connected to the figures in the paper").
    var beats: [PaperWalkthroughBeat]?
    /// Say more chips on the step's cards: context the learner may ask for
    /// (`PaperWalkthroughMore`). Empty on most steps and on every record
    /// written before 2026-09-23.
    var more: [PaperWalkthroughMore] = []
    /// The picture the step's cards show when the step outlines no figure
    /// (`PaperWalkthroughPicture`). Nil on a figure step, on a step that
    /// shows the picture before it, and on every record written before
    /// 2026-09-24.
    var picture: PaperWalkthroughPicture?
    /// The works the step's point rests on, shown under its point cards
    /// (`PaperWalkthroughCitation`). Empty on most steps and on every record
    /// written before 2026-09-30.
    var cites: [PaperWalkthroughCitation] = []

    init(
        id: String,
        kind: Kind,
        title: String,
        body: String,
        anchor: PaperWalkthroughAnchor? = nil,
        animationHTML: String? = nil,
        animationBrief: String? = nil,
        animation: WalkthroughAnimationReference? = nil,
        quiz: PaperWalkthroughQuiz? = nil,
        sourceMention: String? = nil,
        beats: [PaperWalkthroughBeat]? = nil,
        more: [PaperWalkthroughMore] = [],
        picture: PaperWalkthroughPicture? = nil,
        cites: [PaperWalkthroughCitation] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.anchor = anchor
        self.animationHTML = animationHTML
        self.animationBrief = animationBrief
        self.animation = animation
        self.quiz = quiz
        self.sourceMention = sourceMention
        self.beats = beats
        self.more = more
        self.picture = picture
        self.cites = cites
    }

    /// Whether the step shows an animation, inline or by reference.
    var hasAnimation: Bool { animationHTML != nil || animation != nil }

    /// The step's points, one a card: the written beats, or, on a step that
    /// has none, its body a sentence at a time. The authors' sentence about
    /// the panel (`sourceMention`) is not among them since 2026-09-23
    /// (the product owner: "I don't like that they have these quotes on there"): it
    /// stays in the record and in the step's turn, where the tutor reads it,
    /// and on the Mac the sentence is on the page beside the card.
    var pointBeats: [WalkthroughBeat] {
        let written = (beats ?? []).compactMap { beat -> WalkthroughBeat? in
            let text = beat.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return WalkthroughBeat(kind: .point, text: text, anchor: beatAnchor(figureLabel: beat.figureLabel, panelLabel: beat.panelLabel))
        }
        guard written.isEmpty else { return written }
        // A body cut into sentences: a sentence naming one panel of the
        // step's own figure moves the outline to it, so an older step
        // that read "panel a … panel b" walks the panels as it reads them.
        return WalkthroughStepPanelNote.paragraphs(of: body)
            .flatMap(WalkthroughStepPanelNote.sentences(of:))
            .map { sentence in
                WalkthroughBeat(kind: .point, text: sentence, anchor: beatAnchor(figureLabel: nil, panelLabel: soleOwnPanel(in: sentence)))
            }
    }

    /// The cards the deck deals for the step, one a press of Next (product owner,
    /// 2026-09-23: "one point at a time … interspersed with some
    /// questions"): a card per point, and the question as a card of its
    /// own, last. A question step is its question alone — the reminder its
    /// writer gave it rides on the question card as a line of context, not
    /// as a card before it.
    var playableBeats: [WalkthroughBeat] {
        let points = pointBeats
        guard let question = quiz?.question.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            return points
        }
        if kind == .quiz {
            let context = points.map(\.text).joined(separator: " ")
            return [WalkthroughBeat(kind: .question, text: question, context: context.isEmpty ? nil : context)]
        }
        return points + [WalkthroughBeat(kind: .question, text: question)]
    }

    /// How many cards the step takes, never fewer than one: a step with no
    /// words still takes one press to show.
    var cardCount: Int { max(1, playableBeats.count) }

    /// Where a beat points: its own figure and panel, the step's figure at
    /// the beat's panel, or nil — the beat leaves the page where the step,
    /// or the beat before it, put it.
    private func beatAnchor(figureLabel: String?, panelLabel: String?) -> PaperWalkthroughAnchor? {
        let figure = figureLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let panel = panelLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let figure, !figure.isEmpty {
            let pageNumber = PaperWalkthroughValidation.canonicalLabel(figure) == anchor?.figureLabel.map(PaperWalkthroughValidation.canonicalLabel)
                ? anchor?.pageNumber : nil
            return PaperWalkthroughAnchor(figureLabel: figure, panelLabel: panel?.isEmpty == false ? panel : nil, pageNumber: pageNumber)
        }
        guard let panel, !panel.isEmpty, let own = anchor?.figureLabel, !own.isEmpty else { return nil }
        return PaperWalkthroughAnchor(figureLabel: own, panelLabel: panel, pageNumber: anchor?.pageNumber)
    }

    /// The one panel of the step's own figure a sentence names, when it
    /// names exactly one and no other figure.
    private func soleOwnPanel(in sentence: String) -> String? {
        guard let own = anchor?.figureLabel, let number = PaperWalkthroughValidation.figureNumber(of: own) else { return nil }
        if let regex = try? NSRegularExpression(pattern: #"\bfig(?:ure)?s?\.?\s*([A-Za-z]?\d+)"#, options: [.caseInsensitive]) {
            let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
            for match in regex.matches(in: sentence, range: range) {
                guard let found = Range(match.range(at: 1), in: sentence) else { continue }
                if String(sentence[found]).lowercased() != number.lowercased() { return nil }
            }
        }
        let panels = WalkthroughStepPanelNote.panels(in: sentence)
        return panels.count == 1 ? panels.first?.lowercased() : nil
    }

    /// The line a step folds to once the walk has moved past it: its last
    /// point, which the writer makes the takeaway; a question step's is its
    /// question.
    var takeaway: String? {
        playableBeats.last(where: { $0.kind == .point })?.text ?? quiz?.question
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case body
        case anchor
        case animationHTML = "animation_html"
        case animationBrief = "animation_brief"
        case animation = "animation_ref"
        case quiz
        case sourceMention = "source_mention"
        case beats
        case more
        case picture
        case cites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        anchor = try container.decodeIfPresent(PaperWalkthroughAnchor.self, forKey: .anchor)
        animationHTML = try container.decodeIfPresent(String.self, forKey: .animationHTML)
        animationBrief = try container.decodeIfPresent(String.self, forKey: .animationBrief)
        animation = try container.decodeIfPresent(WalkthroughAnimationReference.self, forKey: .animation)
        quiz = try container.decodeIfPresent(PaperWalkthroughQuiz.self, forKey: .quiz)
        sourceMention = try container.decodeIfPresent(String.self, forKey: .sourceMention)
        beats = try container.decodeIfPresent([PaperWalkthroughBeat].self, forKey: .beats)
        // Absent on a record written before Say more chips.
        more = (try? container.decodeIfPresent([PaperWalkthroughMore].self, forKey: .more)) ?? []
        // Absent on a record written before pictures; a malformed one is no picture.
        picture = ((try? container.decodeIfPresent(PaperWalkthroughPicture.self, forKey: .picture)) ?? nil)
            .flatMap { $0.isEmpty ? nil : $0 }
        // Absent on a record written before citations; a malformed list is none.
        cites = (try? container.decodeIfPresent([PaperWalkthroughCitation].self, forKey: .cites)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(anchor, forKey: .anchor)
        try container.encodeIfPresent(animationHTML, forKey: .animationHTML)
        try container.encodeIfPresent(animationBrief, forKey: .animationBrief)
        try container.encodeIfPresent(animation, forKey: .animation)
        try container.encodeIfPresent(quiz, forKey: .quiz)
        try container.encodeIfPresent(sourceMention, forKey: .sourceMention)
        try container.encodeIfPresent(beats, forKey: .beats)
        // Absent when empty, so a record saved before this key encodes as it did.
        if !more.isEmpty { try container.encode(more, forKey: .more) }
        try container.encodeIfPresent(picture, forKey: .picture)
        if !cites.isEmpty { try container.encode(cites, forKey: .cites) }
    }
}

/// One beat as a record stores it: a sentence, and optionally the figure
/// and panel it is about. Written in JSON as a bare string when it points
/// nowhere of its own, `{"text", "figure_label", "panel_label"}` otherwise.
struct PaperWalkthroughBeat: Codable, Equatable, Sendable {
    var text: String
    var figureLabel: String?
    var panelLabel: String?

    init(text: String, figureLabel: String? = nil, panelLabel: String? = nil) {
        self.text = text
        self.figureLabel = figureLabel
        self.panelLabel = panelLabel
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case figureLabel = "figure_label"
        case panelLabel = "panel_label"
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            self.init(text: text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            figureLabel: try container.decodeIfPresent(String.self, forKey: .figureLabel),
            panelLabel: try container.decodeIfPresent(String.self, forKey: .panelLabel)
        )
    }

    func encode(to encoder: Encoder) throws {
        if figureLabel == nil, panelLabel == nil {
            var single = encoder.singleValueContainer()
            try single.encode(text)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(figureLabel, forKey: .figureLabel)
        try container.encodeIfPresent(panelLabel, forKey: .panelLabel)
    }
}

/// One press of Next inside a walkthrough step (`PaperWalkthroughStep.playableBeats`).
struct WalkthroughBeat: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A sentence of the step's own.
        case point
        /// The step's question, answered in the composer.
        case question
        /// A chapter's close: the claim the learner can now say
        /// (`PaperWalkthroughChapter.claim`), with the chapter's title as
        /// context. Dealt after a chapter's last step.
        case recap
        /// The step's animation, alone on its card with no figure above it
        /// (`PaperWalkthrough.playableBeats(of:)`); the text is the step's
        /// title.
        case animation
    }

    let kind: Kind
    let text: String
    /// Where the Reader points while this beat is the newest shown; nil
    /// keeps what the step, or an earlier beat, pointed at.
    var anchor: PaperWalkthroughAnchor? = nil
    /// A line drawn small above the text: on a question card, the reminder
    /// of what the question is about that its writer gave the step.
    var context: String? = nil
}

/// A saved animation a step shows, by reference: a ForeverLM animation
/// (`ArtifactRecord.kind == .animation`, hosted at its own address) pinned
/// to one of its own steps under given conditions. The chat's card loads the
/// animation's page with the kit's walk parameters (`?embed=1&step=N&c=…`,
/// mitochondria `animations/kit/README.md`), so the page shows the stage
/// alone at that step and holds its last frame; a pane showing the same
/// animation beside the chat is pointed at the step instead.
struct WalkthroughAnimationReference: Codable, Hashable, Sendable {
    /// The animation's artifact id.
    var animationID: String
    /// One-based step of the animation's own player.
    var step: Int
    /// Condition id → value, as the animation's page reads them from its
    /// address: a choice's option value, or `1`/`0` for a toggle.
    var conditions: [String: String]

    init(animationID: String, step: Int = 1, conditions: [String: String] = [:]) {
        self.animationID = animationID
        self.step = step
        self.conditions = conditions
    }

    private enum CodingKeys: String, CodingKey {
        case animationID = "animation_id"
        case step
        case conditions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        animationID = try container.decode(String.self, forKey: .animationID)
        step = try container.decodeIfPresent(Int.self, forKey: .step) ?? 1
        conditions = try container.decodeIfPresent([String: String].self, forKey: .conditions) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(animationID, forKey: .animationID)
        try container.encode(step, forKey: .step)
        if !conditions.isEmpty { try container.encode(conditions, forKey: .conditions) }
    }

    /// The query the kit's player reads: `embed=1`, `step=N`, and the
    /// conditions as `c=id:value;id:value`, ids in a fixed order.
    var walkQueryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "embed", value: "1"), URLQueryItem(name: "step", value: String(step))]
        if !conditions.isEmpty {
            let joined = conditions.keys.sorted().map { "\($0):\(conditions[$0] ?? "")" }.joined(separator: ";")
            items.append(URLQueryItem(name: "c", value: joined))
        }
        return items
    }

    /// The animation's address with the walk parameters, for the card to
    /// load. Any earlier walk parameters on the address are replaced.
    func pageURL(animationURL: URL) -> URL {
        guard var components = URLComponents(url: animationURL, resolvingAgainstBaseURL: false) else { return animationURL }
        var items = (components.queryItems ?? []).filter { !["embed", "step", "c"].contains($0.name) }
        items.append(contentsOf: walkQueryItems)
        components.queryItems = items
        return components.url ?? animationURL
    }

    /// "step 5", or "step 5 · iono: nig" when conditions are set.
    var summary: String {
        var text = "step \(step)"
        if !conditions.isEmpty {
            text += " · " + conditions.keys.sorted().map { "\($0): \(conditions[$0] ?? "")" }.joined(separator: ", ")
        }
        return text
    }
}

/// Where in the paper a step points. A figure anchor names the printed label
/// (`Figure 2`) and optionally one panel (`a`); a passage anchor quotes a run
/// of the paper's own words, which the Reader finds on the page the way a chat
/// citation is found. Either may carry the page it expects, one-based, as a
/// hint for a Reader that cannot locate the anchor itself.
struct PaperWalkthroughAnchor: Codable, Hashable, Sendable {
    var figureLabel: String?
    var panelLabel: String?
    var passage: String?
    var pageNumber: Int?
    /// A moment of a video, in whole seconds from its start (2026-09-29): the
    /// Reader seeks the player there, paused, while the step's cards are read.
    /// Only a video's walk carries one (`PaperWalkthroughSubject.allowsMomentAnchors`).
    var seconds: Int?

    init(figureLabel: String? = nil, panelLabel: String? = nil, passage: String? = nil, pageNumber: Int? = nil, seconds: Int? = nil) {
        self.figureLabel = figureLabel
        self.panelLabel = panelLabel
        self.passage = passage
        self.pageNumber = pageNumber
        self.seconds = seconds
    }

    private enum CodingKeys: String, CodingKey {
        case figureLabel = "figure_label"
        case panelLabel = "panel_label"
        case passage
        case pageNumber = "page_number"
        case seconds = "at"
    }

    var isEmpty: Bool {
        (figureLabel?.isEmpty ?? true) && (passage?.isEmpty ?? true) && pageNumber == nil && seconds == nil
    }

    /// "26:51", or "1:02:03" past the hour, for a moment anchor.
    var momentClock: String? {
        guard let seconds, seconds >= 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "Figure 2a", "Figure 3 DESIGN", "Figure 2", or nil for a passage-only
    /// anchor.
    var figureDisplayLabel: String? {
        guard let figureLabel, !figureLabel.isEmpty else { return nil }
        return PaperWalkthroughValidation.figurePanelLabel(figureLabel, panel: panelLabel)
    }
}

/// The picture a step's cards show above their point when the step outlines
/// no figure on the page (product owner, 2026-09-24: "a walkthrough card should
/// always have an image. Like either one of the figures … or there should
/// also be room to just AI generate some images that make the point").
///
/// One of two things: a figure of the source that shows the point
/// (`figureLabel`, `panelLabel`), shown on the card but not outlined on the
/// page — the step's anchor, a passage, stays the Reader's target — or a
/// picture drawn for the step: `brief` says what it should show, and
/// `imageID` names the drawn picture once there is one (a
/// `GeneratedImageStore` id on the device that drew it). A step with no
/// picture shows the one before it in its chapter
/// (`PaperWalkthrough.cardPicture(of:)`), so cards about one idea share one
/// picture and the writer briefs a new one only when the point moves on.
struct PaperWalkthroughPicture: Codable, Hashable, Sendable {
    var figureLabel: String?
    var panelLabel: String?
    /// What the drawn picture should show, as a teaching plan: the point it
    /// makes, what is drawn, what is labelled.
    var brief: String?
    var imageID: String?

    init(figureLabel: String? = nil, panelLabel: String? = nil, brief: String? = nil, imageID: String? = nil) {
        self.figureLabel = figureLabel
        self.panelLabel = panelLabel
        self.brief = brief
        self.imageID = imageID
    }

    private enum CodingKeys: String, CodingKey {
        case figureLabel = "figure_label"
        case panelLabel = "panel_label"
        case brief
        case imageID = "image_id"
    }

    /// Read leniently, as a writer's draft is: a brief handed back as a list
    /// or an object of parts is read as its text, and one malformed field
    /// never loses the step.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        figureLabel = Self.text(in: container, forKey: .figureLabel)
        panelLabel = Self.text(in: container, forKey: .panelLabel)
        imageID = Self.text(in: container, forKey: .imageID)
        if let text = Self.text(in: container, forKey: .brief) {
            brief = text
        } else if let parts = try? container.decodeIfPresent([String].self, forKey: .brief) {
            brief = Self.cleaned(parts.joined(separator: " "))
        } else if let parts = try? container.decodeIfPresent([String: String].self, forKey: .brief) {
            brief = Self.cleaned(parts.sorted { $0.key < $1.key }.map(\.value).joined(separator: " "))
        } else {
            brief = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(figureLabel, forKey: .figureLabel)
        try container.encodeIfPresent(panelLabel, forKey: .panelLabel)
        try container.encodeIfPresent(brief, forKey: .brief)
        try container.encodeIfPresent(imageID, forKey: .imageID)
    }

    var isEmpty: Bool { figureLabel == nil && brief == nil && imageID == nil }

    /// The figure as an anchor the resolver can crop, or nil for a drawn
    /// picture.
    var figureAnchor: PaperWalkthroughAnchor? {
        guard let figureLabel else { return nil }
        return PaperWalkthroughAnchor(figureLabel: figureLabel, panelLabel: panelLabel)
    }

    /// Lowercase hex and dashes, 8–64 characters: the shape of a
    /// `GeneratedImageReference` id, checked here too because the phone
    /// decodes the record without that type.
    static func isValidImageID(_ id: String) -> Bool {
        guard (8...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isNumber || ("a"..."f").contains($0) || $0 == "-" }
    }

    private static func text(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        cleaned((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What a card shows above its point (`PaperWalkthrough.cardPicture(of:)`).
enum WalkthroughCardPicture: Equatable, Sendable {
    /// The figure the step outlines on the page: its anchor's, followed
    /// panel by panel as its beats name them — the card's picture before
    /// pictures were written.
    case anchoredFigure
    /// A figure of the source the step does not outline: its own picture,
    /// or the figure an earlier step of the chapter showed.
    case figure(PaperWalkthroughAnchor)
    /// A picture drawn for the step, or for an earlier step of the chapter:
    /// the id and the brief it was drawn from.
    case drawn(imageID: String, brief: String?)
}

/// How a walk's drawn pictures ride its Source record, read by the Mac that
/// packs and applies it (`WalkthroughPicturePackage`) and by the phone that
/// shows it (`MobileSourceFileStore.walkthroughPicture`).
///
/// The field is one `CKAsset`: a binary property list of store file name
/// (`<id>.<ext>`) → the file's bytes as stored, prompt and version in their
/// XMP, plus one entry under `manifestName` whose bytes are a binary
/// property list of the id each step names → the file name shown for it (the
/// image's latest version when the step names the image, else that version
/// as redrawn). A Mac rebuilds what it shows from the files' own XMP; the
/// phone, which keeps no image store, reads the manifest.
enum WalkthroughPicturePackageFormat {
    static let field = "walkthroughPicturesAsset"
    /// Not a store file name (`GeneratedImageReference.isValidID` refuses
    /// it), so a Mac writing the package into its store skips it.
    static let manifestName = "shown.plist"
}

/// An open question about what the step just showed, answered in the
/// learner's own words and graded by a model against the writer's reference
/// answer and key points (product owner, 2026-09-19: "do NOT put multiple choice
/// questions in there, they can just be chat based questions which is way more
/// effective for recall").
///
/// The JSON key on the step is still `quiz` and the step kind is still `quiz`,
/// because both are in every saved record. A record written before this
/// carried `options` and `correct_index` instead of `answer`; it decodes to
/// the same open question, with the option marked correct (and its
/// explanation) as the reference answer, so an old walk is not thrown away
/// and never shows radio buttons again.
struct PaperWalkthroughQuiz: Codable, Equatable, Sendable {
    /// How the question is asked (2026-09-23, the lesson's four kinds
    /// merged in). Every kind is open and answered in the learner's words —
    /// or graded by the learner after Show answer — except Find it, which is
    /// answered by picking a panel.
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// About what the cards just showed; asked after the evidence.
        case recall
        /// Asked before the evidence: what would you need to show, what
        /// would you expect, why would the authors do this.
        case thinkFirst = "think_first"
        /// The step's panel is hidden until the learner commits to a guess;
        /// `answer` says what the data show.
        case predict
        /// Answered on the figure: the learner picks the panel that shows
        /// something (`targetPanel`); `answer` says what that panel shows.
        case find

        /// The word over the question on its card.
        var label: String {
            switch self {
            case .recall: return "Question"
            case .thinkFirst: return "Think first"
            case .predict: return "Predict"
            case .find: return "Find it"
            }
        }
    }

    var question: String
    /// The reference answer, a sentence or two, shown after grading.
    var answer: String
    /// What a complete answer mentions; the grader checks each.
    var keyPoints: [String]
    var kind: Kind = .recall
    /// Find it: the panel letter that answers, of the step's figure.
    var targetPanel: String?

    init(question: String, answer: String, keyPoints: [String] = [], kind: Kind = .recall, targetPanel: String? = nil) {
        self.question = question
        self.answer = answer
        self.keyPoints = keyPoints
        self.kind = kind
        self.targetPanel = targetPanel
    }

    private enum CodingKeys: String, CodingKey {
        case question
        case answer
        case keyPoints = "key_points"
        case kind
        case targetPanel = "target_panel"
        // The multiple-choice shape saved before 2026-09-19; read, never written.
        case options
        case correctIndex = "correct_index"
        case explanation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        // A kind a later build adds, or none, reads as the plain question.
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .recall
        targetPanel = try container.decodeIfPresent(String.self, forKey: .targetPanel)
        if kind != .find { targetPanel = nil }
        if let answer = try container.decodeIfPresent(String.self, forKey: .answer),
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.answer = answer
        } else {
            answer = Self.legacyReferenceAnswer(
                options: try container.decodeIfPresent([String].self, forKey: .options) ?? [],
                correctIndex: try container.decodeIfPresent(Int.self, forKey: .correctIndex),
                explanation: try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(answer, forKey: .answer)
        try container.encode(keyPoints, forKey: .keyPoints)
        // Absent for the plain question, so a record saved before kinds
        // encodes as it did.
        if kind != .recall { try container.encode(kind, forKey: .kind) }
        if kind == .find { try container.encodeIfPresent(targetPanel, forKey: .targetPanel) }
    }

    /// The option a multiple-choice question marked correct, with its
    /// explanation, as the reference answer an open question grades against.
    static func legacyReferenceAnswer(options: [String], correctIndex: Int?, explanation: String) -> String {
        var parts: [String] = []
        if let correctIndex, correctIndex >= 0, correctIndex < options.count {
            let option = options[correctIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !option.isEmpty { parts.append(option) }
        }
        let why = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty { parts.append(why) }
        return parts.joined(separator: " ")
    }

    var isValid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - What the writer returns

/// The writer's answer: the steps without ids or animations. Turned into a
/// `PaperWalkthrough` by `PaperWalkthroughValidation`, which checks every
/// anchor against the paper before anything is saved.
struct PaperWalkthroughDraft: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var kind: String
        var title: String
        var body: String
        var figureLabel: String?
        var panelLabel: String?
        var passage: String?
        var pageNumber: Int?
        var animationBrief: String?
        var quiz: PaperWalkthroughQuiz?
        var beats: [PaperWalkthroughBeat]?
        /// Say more chips; empty when none were written.
        var more: [PaperWalkthroughMore] = []
        /// The card's picture on a step that outlines no figure.
        var picture: PaperWalkthroughPicture?
        /// The works the step's point rests on; empty when none were named.
        var cites: [PaperWalkthroughCitation] = []

        private enum CodingKeys: String, CodingKey {
            case kind
            case title
            case body
            case beats
            case more
            case picture
            case cites
            case figureLabel = "figure_label"
            case panelLabel = "panel_label"
            case passage
            case pageNumber = "page_number"
            case animationBrief = "animation_brief"
            case quiz
        }

        init(
            kind: String,
            title: String,
            body: String,
            figureLabel: String?,
            panelLabel: String?,
            passage: String?,
            pageNumber: Int?,
            animationBrief: String?,
            quiz: PaperWalkthroughQuiz?,
            beats: [PaperWalkthroughBeat]? = nil,
            more: [PaperWalkthroughMore] = [],
            picture: PaperWalkthroughPicture? = nil,
            cites: [PaperWalkthroughCitation] = []
        ) {
            self.kind = kind
            self.title = title
            self.body = body
            self.figureLabel = figureLabel
            self.panelLabel = panelLabel
            self.passage = passage
            self.pageNumber = pageNumber
            self.animationBrief = animationBrief
            self.quiz = quiz
            self.beats = beats
            self.more = more
            self.picture = picture
            self.cites = cites
        }

        /// A step written as beats may leave `body` out.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            beats = try container.decodeIfPresent([PaperWalkthroughBeat].self, forKey: .beats)
            figureLabel = try container.decodeIfPresent(String.self, forKey: .figureLabel)
            panelLabel = try container.decodeIfPresent(String.self, forKey: .panelLabel)
            passage = try container.decodeIfPresent(String.self, forKey: .passage)
            pageNumber = try container.decodeIfPresent(Int.self, forKey: .pageNumber)
            animationBrief = Self.flexibleText(in: container, forKey: .animationBrief)
            quiz = try container.decodeIfPresent(PaperWalkthroughQuiz.self, forKey: .quiz)
            // One malformed chip must not lose the step.
            more = (try? container.decodeIfPresent([PaperWalkthroughMore].self, forKey: .more)) ?? []
            // Nor one malformed picture.
            picture = (try? container.decodeIfPresent(PaperWalkthroughPicture.self, forKey: .picture)) ?? nil
            // Nor a malformed citation list.
            cites = (try? container.decodeIfPresent([PaperWalkthroughCitation].self, forKey: .cites)) ?? []
        }

        /// A brief is a teaching plan in order, and a writer sometimes hands
        /// it back structured — an object of parts, or a list — rather than
        /// as text. One such step made the whole draft undecodable
        /// (2026-09-22: step 28 of the cardiac-sodium walk, `{"": "…"}`, and
        /// the walk failed as "Invalid AI response"). Any shape is read as
        /// its text, in order; anything else is no brief.
        private static func flexibleText(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
            if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
            if let parts = try? container.decodeIfPresent([String].self, forKey: key) {
                return parts.joined(separator: " ")
            }
            if let parts = try? container.decodeIfPresent([String: String].self, forKey: key) {
                return parts.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
            }
            return nil
        }
    }

    /// A chapter the writer grouped steps under: one claim of the source
    /// and the steps that teach it (2026-09-23).
    struct Chapter: Codable, Equatable, Sendable {
        var title: String
        var claim: String
        var steps: [Step]

        init(title: String, claim: String, steps: [Step]) {
            self.title = title
            self.claim = claim
            self.steps = steps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            claim = try container.decodeIfPresent(String.self, forKey: .claim) ?? ""
            steps = (try? container.decodeIfPresent([Step].self, forKey: .steps)) ?? []
        }
    }

    var title: String
    /// Every step in order — the flat list an older writer returns, or the
    /// chapters' steps run together.
    var steps: [Step]
    /// The chapters, when the writer grouped the steps; nil for a flat
    /// draft. Each chapter's steps are a slice of `steps`, in order.
    var chapters: [Chapter]?

    init(title: String, steps: [Step], chapters: [Chapter]? = nil) {
        self.title = title
        self.steps = steps
        self.chapters = chapters
    }

    init(title: String, chapters: [Chapter]) {
        self.title = title
        self.chapters = chapters
        self.steps = chapters.flatMap(\.steps)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case steps
        case chapters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let flat = (try? container.decodeIfPresent([Step].self, forKey: .steps)) ?? nil
        let grouped = ((try? container.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? nil)?
            .filter { !$0.steps.isEmpty }
        if let grouped, !grouped.isEmpty {
            chapters = grouped
            steps = grouped.flatMap(\.steps)
        } else {
            chapters = nil
            steps = flat ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        if let chapters, !chapters.isEmpty {
            try container.encode(chapters, forKey: .chapters)
        } else {
            try container.encode(steps, forKey: .steps)
        }
    }
}

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
    static let minimumSteps = 2
    /// Steps that are not questions. Raised from 24 on 2026-09-21, when a
    /// figure step became one panel: a paper with five four-panel figures
    /// needs the room.
    static let maximumSteps = 40
    /// Questions, counted apart from `maximumSteps`: the writer is asked for
    /// ten to thirty steps "not counting the questions", and one question
    /// every two or three steps and at each chapter's end. Counting them
    /// together refused a 44-step walk the prompt had asked for (the
    /// MitoSpace paper, 2026-09-23).
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
            // against (the lesson's rule, merged 2026-09-23): a Find it
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
        // panels come in order, and the figures come in printed order. (From
        // 2026-09-23 to 2026-09-29 a panel left out went unwarned, since the
        // walk teaches claims; the claims stay, and a figure the walk shows
        // is addressed whole again, the product owner's 2026-09-19 rule.)
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
    /// about again since 2026-09-29: for every figure whose panels are known
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
    /// otherwise (2026-09-29: the walk of "Engineered human resilience and
    /// durability" outlined Figure 3 at its third step, before Figures 1 and
    /// 2). Names each step that first outlines a figure while a lower-numbered
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
    /// does not end in a letter. Until 2026-09-29 a name counted as its last
    /// letter, so the four columns of a funnel figure labelled ALL OF
    /// BIOLOGY, FUNCTION RETRIEVAL, DESIGN and VALIDATION were Y, L, N and
    /// N, and VALIDATION's rectangle took DESIGN's place.
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

// MARK: - Figure titles

/// The title a figure prints at the head of its caption, for the panel to
/// show under a step (product owner, 2026-09-19: "for each figure it actually also
/// says the figure title in the walkthrough; that's probably helpful").
///
/// A caption opens with its label, a separator and a title sentence, then
/// the panel descriptions: "Fig. 1. Atlas of lysosomal changes … GPDs. (A)
/// Schematic …", "Figure 2 | A mitochondrial electron surplus induces sleep.
/// a, Schematic …". The title is what stands between the label and the first
/// sentence end that is not an abbreviation. This reads structure, not
/// meaning — the label the indexer already recognises, then a sentence — and
/// stops there.
enum PaperFigureCaptionTitle {
    static let maximumTitleCharacters = 220
    static let maximumPanelCaptionCharacters = 320

    /// The whole legend with its label taken off, on one line: "Fig. 1. Atlas
    /// of lysosomal changes during aging reveals accumulation of cystine and
    /// GPDs. (A) …" → "Atlas of lysosomal changes during aging reveals
    /// accumulation of cystine and GPDs. (A) …". Empty when only the label
    /// was printed.
    static func words(from caption: String) -> String {
        var text = collapsed(caption)
        if let regex = try? NSRegularExpression(
            pattern: #"^\s*(?:(?:supplementary|supplemental|extended\s+data)\s+)?(?:figure|fig\.?)\s*[A-Za-z]?\d+(?:[.\-–]\d+)?[A-Za-z]?\s*[.|:\-–—]?\s*"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), let labelRange = Range(match.range, in: text) {
                text.removeSubrange(labelRange)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "Fig. 1. Atlas of lysosomal changes during aging reveals accumulation
    /// of cystine and GPDs. (A) …" → "Atlas of lysosomal changes during aging
    /// reveals accumulation of cystine and GPDs". Nil when nothing follows the
    /// label.
    static func title(from caption: String) -> String? {
        let text = words(from: caption)
        guard !text.isEmpty else { return nil }
        var title = String(text[..<(sentenceEnd(in: text) ?? text.endIndex)])
        if let pipe = title.range(of: " | ") { title = String(title[..<pipe.lowerBound]) }
        title = title.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".:;,|"))
        guard !title.isEmpty else { return nil }
        if title.count > maximumTitleCharacters {
            title = String(title.prefix(maximumTitleCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    /// Whether a caption line is Nature's placeholder under a figure that
    /// fills its page — "Extended Data Fig. 1 | See next page for caption." —
    /// with the words printed on the page after. Such a row stays in the
    /// index as it is (its line is what the crop locator finds on the
    /// figure's page); whoever shows the words reads the continuation row
    /// instead (`PaperWalkthroughGeneratorService.displayCaption`).
    static func isContinuedCaption(_ caption: String) -> Bool {
        guard let body = title(from: caption)?.lowercased() else { return false }
        let stubs = ["see next page", "see the next page", "see following page", "see the following page",
                     "caption on next page", "legend on next page", "continued on next page", "caption overleaf",
                     "see previous page", "see the previous page", "see preceding page", "see the preceding page",
                     "caption on previous page", "legend on previous page"]
        return stubs.contains { body.hasPrefix($0) }
    }

    /// Whether a caption line prints its figure's label and none of its
    /// words: EMBO's "Figure 1." under a figure whose legend is set on the
    /// page before or after it (the EMBO cristae paper, 2026-09-28), or a
    /// pointer to that page, Nature's "Fig. 3 | See next page for caption."
    /// A stub is printed with the figure; the words are somewhere else.
    static func isStub(_ caption: String) -> Bool {
        title(from: caption) == nil || isContinuedCaption(caption)
    }

    /// Whether a caption is an entry in a list of figures: the label, the
    /// title, and a run of leader dots to the page number ("Figure 1.1 The
    /// cardiac action potential. ........ 20"). A legend never prints six dots
    /// in a row, prose does not, and the entry's title may wrap, so the dots
    /// are looked for in the whole caption. Until index version 8 a thesis's
    /// List of Figures was 76 figures, each a box over its page, beside the
    /// real ones.
    static func isContentsEntry(_ caption: String) -> Bool {
        guard let regex = contentsLeaderRegex else { return false }
        return regex.firstMatch(in: caption, range: NSRange(caption.startIndex..<caption.endIndex, in: caption)) != nil
    }

    private static let contentsLeaderRegex = try? NSRegularExpression(
        pattern: #"(?:\.[ \x{00A0}]?){6,}|\x{2026}[ \x{00A0}]?(?:\x{2026}[ \x{00A0}]?){1,}"#
    )

    /// Where a line's caption begins: after the marks some journals set
    /// before it. EMBO points from a legend to the page its figure is on —
    /// "◀ Figure 2. The DΨm-sensitive dye…" opens the page after Figure 2 —
    /// and until 2026-09-28 the arrow hid six of the cristae paper's eleven
    /// legends from the index. Nil when the line is only marks.
    static func captionStart(in line: String) -> String.Index? {
        line.firstIndex { character in
            !character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
    }

    /// The label a caption line opens with — "Figure 3", "Extended Data
    /// Figure 1" — or nil for any other line. Marks before the caption
    /// (`captionStart`) are passed over.
    static func label(openingLine line: String) -> String? {

        // Textbooks number figures by chapter ("Figure 3-4", "Figure 3–4",
        // "Figure 3.4"); the joined number is the identifier, so a dash or dot
        // between the digits is part of the label rather than the end of it.
        //
        // The panel letters are matched case-*sensitively*, inside an otherwise
        // case-insensitive pattern, and that is the whole difference between a
        // caption and a sentence. Journals print panels lower case in prose
        // ("senescent cells (Fig. 2a, b)") and upper case in the rare caption
        // that stands alone ("Figure 3B | …"). Extracted page text breaks lines
        // mid-sentence, so a reference lands at the start of a line often
        // enough that a case-blind `[A-Z]?` indexed "Figure 2a", "Figure 5d" and
        // "Figure 11h" as figures of their own — labels that name nothing, and
        // that the tools then offered as available figures.
        //
        // A reference that happens to open a line is told from a caption by
        // what follows the number. A caption continues with a separator or its
        // title ("Fig. 2 | A mitochondrial…", "Figure 3. Regeneration",
        // "FIGURE 3–5 Fermentation"); a reference continues with the close of
        // its parenthesis, a list comma, or the rest of its sentence
        // ("(Extended Data\nFig. 2) offers", "Fig. 2). However", "Figure 2
        // shows"). Nature's extracted text opened two lines of one page of the
        // 2025 sleep-pressure paper with "Fig. 2)", the page before the figure:
        // both were indexed as Figure 2 there, so "Figure 2" resolved to prose,
        // and the same label twice on one page is what the index table refuses,
        // which cost the paper its whole index.
        //
        // A paper's Extended Data and Supplementary figures are figures too
        // ("Extended Data Fig. 1 | Correlation matrix …", "Supplementary
        // Figure 2. Sensitivity …"): Nature prints the Extended Data at the
        // back of the same PDF, and a walkthrough should be able to point at
        // them wherever they help (product owner, 2026-09-20). The prefix is kept in
        // the label — "Extended Data Figure 1" is not "Figure 1" — so the two
        // never collide in the index, and "Fig." is normalised to "Figure" as
        // it is for a main figure. Until index version 2 these lines were
        // skipped, so a Nature paper lost every Extended Data figure.
        guard let regex = captionOpeningRegex, let start = captionStart(in: line) else { return nil }
        let line = String(line[start...])
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 2,
              let identifierRange = Range(match.range(at: 2), in: line) else { return nil }
        let prefix = Range(match.range(at: 1), in: line).map { normalizedFigurePrefix(String(line[$0])) }
        return ([prefix, "Figure \(line[identifierRange])"].compactMap { $0 }).joined(separator: " ")
    }

    private static let captionOpeningRegex = try? NSRegularExpression(
        pattern: #"^(?:(Extended\s+Data|Supplementary|Supplemental)\s+)?(?:Figure|Fig\.)\s+((?-i:[A-Z])?\d+(?:[.\-–]\d+)?(?-i:[A-Z])?)\b(?!\s*(?:[),;]|(?-i:[a-z]))).*"#,
        options: [.caseInsensitive]
    )

    /// "extended  data" → "Extended Data", "SUPPLEMENTARY" → "Supplementary":
    /// the prefix as the label prints it, whatever case the caption used.
    private static func normalizedFigurePrefix(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// What the caption says about one panel: the text after "(A)", "A,", "A."
    /// or "a)" up to the next panel's marker or the caption's end. Nil when the
    /// caption does not describe panels that way.
    static func panelCaption(for panel: String, in caption: String) -> String? {
        guard let letter = PaperWalkthroughValidation.panelLetter(panel) else { return nil }
        let text = collapsed(caption)
        let escaped = NSRegularExpression.escapedPattern(for: letter)
        // The marker: "(A)" anywhere, or "A," / "A." / "A)" at a sentence start.
        guard let marker = try? NSRegularExpression(
            pattern: #"(?:\(\s*"# + escaped + #"\s*\)|(?:^|(?<=[.;:] ))"# + escaped + #"\s*[,.)])\s*"#,
            options: [.caseInsensitive]
        ), let next = try? NSRegularExpression(
            pattern: #"(?:\(\s*[A-Za-z]\s*\)|(?<=[.;:] )[A-Za-z]\s*[,.)] )"#
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = marker.firstMatch(in: text, range: range),
              let start = Range(match.range, in: text) else { return nil }
        let rest = String(text[start.upperBound...])
        let restRange = NSRange(rest.startIndex..<rest.endIndex, in: rest)
        var body = rest
        if let following = next.firstMatch(in: rest, range: restRange), let cut = Range(following.range, in: rest) {
            body = String(rest[..<cut.lowerBound])
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.count > maximumPanelCaptionCharacters {
            body = String(body.prefix(maximumPanelCaptionCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return body
    }

    /// The index after the first sentence-ending period that is not an
    /// abbreviation ("E. coli", "et al.", "vs.", "Fig."), or nil when the text
    /// has none.
    static func sentenceEnd(in text: String) -> String.Index? {
        var searchStart = text.startIndex
        while let dot = text[searchStart...].firstIndex(of: ".") {
            let after = text.index(after: dot)
            let endsHere = after == text.endIndex || text[after].isWhitespace
            if endsHere {
                let before = text[..<dot]
                let lastWord = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                let abbreviation = lastWord.count <= 1
                    || ["al", "vs", "fig", "figs", "approx", "ca", "cf", "e.g", "i.e", "no", "et", "spp", "sp"]
                        .contains(lastWord.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()")))
                if !abbreviation { return dot }
            }
            searchStart = after
        }
        return nil
    }

    /// The caption as one line. A stored caption keeps the page's line breaks
    /// (`PDFTextExtractor.figureCaptionRecords(on:)`), and a word the column
    /// broke at a hyphen — "para-" / "aminoblebbistatin" — closes up again
    /// rather than reading "para- aminoblebbistatin".
    static func collapsed(_ text: String) -> String {
        var joined = text
        if let regex = try? NSRegularExpression(pattern: #"-[ \t]*\n[ \t]*(?=[a-z])"#) {
            let range = NSRange(joined.startIndex..<joined.endIndex, in: joined)
            joined = regex.stringByReplacingMatches(in: joined, range: range, withTemplate: "-")
        }
        return joined.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - A panel's own words

/// What the step itself says about one panel of a figure. The letter chips
/// over a figure step move the outline from panel to panel; pressing one has
/// to say what that panel shows as well as point at it (product owner, 2026-09-21:
/// "when I click A, it just shows the highlight over A, but it should really
/// show this short explanation of what it shows"). The figure's printed
/// caption answers first where it describes its panels
/// (`PaperFigureCaptionTitle.panelCaption`); where it does not, the step's own
/// body does. A figure step takes its panels in turn by name, so a panel's
/// note is the sentence that names it plus the sentences that carry on about
/// it, and it ends where the next panel is named.
///
/// This reads structure, not meaning: sentences, and the letters a sentence
/// names as a panel — "panel b", "panels a and b", "panels a–c", "(c)",
/// "Fig. 1d". A letter standing alone in prose is not a panel.
enum WalkthroughStepPanelNote {
    /// About a short paragraph. Longer than a caption's panel sentence
    /// because the step's own words run to two or three sentences a panel.
    static let maximumCharacters = 420

    /// The step's note for one panel, or nil when its body never names it.
    static func note(for panel: String, inBody body: String) -> String? {
        guard let letter = PaperWalkthroughValidation.panelLetter(panel) else { return nil }
        for paragraph in paragraphs(of: body) {
            let sentences = sentences(of: paragraph)
            guard let start = sentences.firstIndex(where: { panels(in: $0).contains(letter) }) else { continue }
            var note = sentences[start]
            var index = start + 1
            while index < sentences.count {
                let next = sentences[index]
                let named = panels(in: next)
                // A sentence that names another panel has left this one.
                guard named.isEmpty || named == [letter] else { break }
                guard note.count + 1 + next.count <= maximumCharacters else { break }
                note += " " + next
                index += 1
            }
            if note.count > maximumCharacters {
                note = String(note.prefix(maximumCharacters)).trimmingCharacters(in: .whitespaces) + "…"
            }
            return note
        }
        return nil
    }

    /// The panel letters a sentence names, upper case.
    static func panels(in sentence: String) -> Set<String> {
        var found: Set<String> = []
        let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
        // "panel b", "panels a and b", "panels c, d", "panels a–c". The list
        // runs while letters are joined by a separator; "panel a, the plot"
        // captures "a, t" and keeps only the letter standing alone.
        // Each letter must stand alone: "panel a, the plot" stops at "a"
        // because "the" carries on, and "the panels validate" names nothing.
        if let list = try? NSRegularExpression(
            pattern: #"\bpanels?\s+([A-Za-z](?![A-Za-z])(?:\s*(?:,|and|&|or|to|through|–|—|-)\s*[A-Za-z](?![A-Za-z]))*)"#,
            options: [.caseInsensitive]
        ) {
            for match in list.matches(in: sentence, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: sentence) else { continue }
                found.formUnion(letters(inList: String(sentence[captured])))
            }
        }
        // "(c)" on its own, and "Fig. 1d" / "Figure 2B".
        for pattern in [#"\(\s*([A-Za-z])\s*\)"#,
                        #"\b(?:fig(?:ure)?s?\.?\s*)[A-Za-z]?\d+(?:[.\-–]\d+)?([A-Za-z])\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: sentence, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: sentence) else { continue }
                found.insert(String(sentence[captured]).uppercased())
            }
        }
        return found
    }

    /// The letters standing alone in a captured list, with "a–c" and "a to c"
    /// opened out into the letters between.
    private static func letters(inList list: String) -> Set<String> {
        var found: Set<String> = []
        guard let single = try? NSRegularExpression(pattern: #"(?<![A-Za-z])([A-Za-z])(?![A-Za-z])"#) else { return [] }
        let range = NSRange(list.startIndex..<list.endIndex, in: list)
        var standing: [String] = []
        for match in single.matches(in: list, range: range) {
            guard let captured = Range(match.range, in: list) else { continue }
            standing.append(String(list[captured]).uppercased())
        }
        found.formUnion(standing)
        if let span = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z])([A-Za-z])\s*(?:–|—|-|to|through)\s*([A-Za-z])(?![A-Za-z])"#,
            options: [.caseInsensitive]
        ) {
            for match in span.matches(in: list, range: range) where match.numberOfRanges > 2 {
                guard let first = Range(match.range(at: 1), in: list),
                      let last = Range(match.range(at: 2), in: list),
                      let from = String(list[first]).uppercased().unicodeScalars.first?.value,
                      let to = String(list[last]).uppercased().unicodeScalars.first?.value,
                      from < to, to - from < 12 else { continue }
                for value in from...to {
                    guard let scalar = Unicode.Scalar(value) else { continue }
                    found.insert(String(Character(scalar)))
                }
            }
        }
        return found
    }

    /// The body's paragraphs as plain one-line prose: blank lines separate,
    /// single newlines join, and Markdown's marks come off so a bold "**Panel
    /// b**" reads as words.
    static func paragraphs(of body: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            let paragraph = plain(current.joined(separator: " "))
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            current.removeAll()
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return paragraphs
    }

    /// Whether the step's body takes several panels in turn — the shape a
    /// walk written before 2026-09-21 gave a multi-panel figure, one step
    /// reading "panel a … panel b … panel c" under one outline. Only such a
    /// step has words for one panel that are not simply its opening; a step
    /// about one panel says it all in the bubble already.
    static func toursSeveralPanels(_ body: String) -> Bool {
        var named: Set<String> = []
        for paragraph in paragraphs(of: body) {
            for sentence in sentences(of: paragraph) {
                named.formUnion(panels(in: sentence))
                if named.count > 1 { return true }
            }
        }
        return false
    }

    private static func plain(_ text: String) -> String {
        var copy = text
        for mark in ["**", "__", "`", "*", "_"] { copy = copy.replacingOccurrences(of: mark, with: "") }
        if let leading = try? NSRegularExpression(pattern: #"^\s*(?:#{1,6}\s*|[-*+]\s+|>\s*|\d+\.\s+)"#) {
            let range = NSRange(copy.startIndex..<copy.endIndex, in: copy)
            if let match = leading.firstMatch(in: copy, range: range), let found = Range(match.range, in: copy) {
                copy.removeSubrange(found)
            }
        }
        return copy.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A paragraph cut into sentences. A full stop ends one when it is not an
    /// abbreviation (`PaperFigureCaptionTitle.sentenceEnd`) and what follows
    /// is space or the end, with a closing quote or bracket allowed between —
    /// papers write `“Time (min).”` mid-sentence.
    static func sentences(of paragraph: String) -> [String] {
        var sentences: [String] = []
        var start = paragraph.startIndex
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            let character = paragraph[index]
            var after = paragraph.index(after: index)
            if character == "." || character == "?" || character == "!" {
                while after < paragraph.endIndex, "”\"’')]".contains(paragraph[after]) {
                    after = paragraph.index(after: after)
                }
                let closes = after == paragraph.endIndex || paragraph[after].isWhitespace
                let abbreviation = character == "." && isAbbreviation(paragraph[start..<index])
                if closes && !abbreviation {
                    let sentence = paragraph[start..<after].trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { sentences.append(sentence) }
                    start = after
                    index = after
                    continue
                }
            }
            index = paragraph.index(after: index)
        }
        let tail = paragraph[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Whether the word before a full stop is one that is written with one
    /// ("et al.", "vs.", "Fig.", "E. coli").
    private static func isAbbreviation<S: StringProtocol>(_ before: S) -> Bool {
        let word = String(before).components(separatedBy: .whitespaces).last ?? ""
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()“”\"‘’"))
        return bare.count <= 1
            || ["al", "vs", "fig", "figs", "approx", "ca", "cf", "e.g", "i.e", "no", "et", "spp", "sp", "ref", "refs"]
                .contains(bare)
    }
}

// MARK: - JSON

enum PaperWalkthroughCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func json(_ walkthrough: PaperWalkthrough) throws -> String {
        String(decoding: try encoder().encode(walkthrough), as: UTF8.self)
    }

    static func walkthrough(fromJSON json: String) throws -> PaperWalkthrough {
        try decoder().decode(PaperWalkthrough.self, from: Data(json.utf8))
    }
}

// MARK: - The text's own sentence about a figure

/// The sentence of a source's own text that cites a figure's panel — the
/// place where the authors say what Figure 1a shows — found without a model,
/// so a figure step can repeat the authors' words beside the outline
/// (product owner, 2026-09-21: "when it highlights e.g. figure 1a; perhaps it would
/// be helpful to also repeat the sentence in the paper where they explain
/// figure 1a").
///
/// A citation is read the way papers print one: the figure's number after
/// "Fig.", "Figs.", "Figure" or "Figures", with the panel glued to it or in
/// brackets ("Fig. 1a", "Figure 1A", "Fig. 1(a)") and any list or range that
/// follows ("Fig. 1a,b", "Figs. 1a and b", "Fig. 1a–c"). "Figure 12" is not
/// Figure 1, and a main figure's citation is never the extended-data or
/// supplementary figure of the same number, nor the other way round. The
/// caption is not a citation: it opens with the label, and the chip beside
/// the step already shows it.
enum PaperFigureMention {
    /// Words a sentence may run to and still be repeated whole; a longer one
    /// is passed over for the next.
    static let maximumWords = 120
    /// Fewer words than this is a fragment the splitter left, not a sentence.
    static let minimumWords = 4

    /// The first sentence of `text`, outside the figure's caption, that cites
    /// `panel` of the figure labelled `label`; when no sentence cites that
    /// panel, the first that cites the figure as a whole ("Fig. 1", no
    /// panel named); nil when nothing does. `panel` nil asks for the figure
    /// itself. The sentence comes back readable — line breaks closed,
    /// broken words joined — not case-folded.
    static func sentence(citing label: String, panel: String?, in text: String) -> String? {
        guard !text.isEmpty, let pattern = mentionPattern(for: label),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let wanted = panel.flatMap(PaperWalkthroughValidation.panelLetter)?.lowercased()
        // A named panel ("DESIGN") is never cited by letter; the sentence
        // about the figure as a whole is the one that speaks for it.
        let asksForPanel = wanted != nil || panel.flatMap(PaperWalkthroughValidation.panelKey) != nil
        let canonical = PaperWalkthroughValidation.canonicalLabel(label)
        var wholeFigure: String?
        for sentence in sentences(in: text) {
            let range = NSRange(sentence.startIndex..., in: sentence)
            let matches = regex.matches(in: sentence, range: range)
            guard !matches.isEmpty else { continue }
            guard !isCaption(sentence, canonical: canonical, firstMatch: matches[0]) else { continue }
            let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
            guard words >= minimumWords, words <= maximumWords else { continue }
            var citesPanel = false
            var citesFigure = false
            for match in matches {
                guard let end = Range(match.range, in: sentence)?.upperBound else { continue }
                let panels = panelsCited(in: sentence, after: end)
                if panels.isEmpty { citesFigure = true }
                if let wanted, panels.contains(wanted) { citesPanel = true }
            }
            if !asksForPanel {
                if citesFigure || !matches.isEmpty { return sentence }
            } else if citesPanel {
                return sentence
            } else if citesFigure, wholeFigure == nil {
                wholeFigure = sentence
            }
        }
        return wholeFigure
    }

    /// The panel letters a citation names, read off the text right after the
    /// figure's number, lower-cased: the first glued to the number or in
    /// brackets, the rest after commas, "and", "&" or a dash, a dash or "to"
    /// spanning a range ("a–c" is a, b and c). Empty when the citation is of
    /// the whole figure, or the next word is not a panel ("Fig. 1 and 2").
    static func panelsCited(in sentence: String, after start: String.Index) -> [String] {
        let rest = String(sentence[start...])
        guard let first = firstPanel.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return [] }
        var letters: [String] = []
        var upperCase = false
        for group in 1...2 {
            if let range = Range(first.range(at: group), in: rest) {
                let letter = String(rest[range])
                upperCase = letter == letter.uppercased()
                letters.append(letter.lowercased())
            }
        }
        var cursor = Range(first.range, in: rest)!.upperBound
        while let next = nextPanel.firstMatch(in: rest, range: NSRange(cursor..., in: rest)) {
            guard let letterRange = Range(next.range(at: 2), in: rest),
                  let separatorRange = Range(next.range(at: 1), in: rest) else { break }
            let letter = String(rest[letterRange])
            // The list keeps one case: "Fig. 1A, B" names B, "Fig. 1A, a
            // decrease" does not.
            guard (letter == letter.uppercased()) == upperCase else { break }
            let lowered = letter.lowercased()
            // "a" and "i" are words as well as panels; after a separator they
            // count only when the list goes on or closes right after them.
            if lowered == "a" || lowered == "i" {
                let after = rest[letterRange.upperBound...].first
                guard after == nil || ",;.)]".contains(after!) || nextPanelContinues(rest, from: letterRange.upperBound) else { break }
            }
            let separator = rest[separatorRange].trimmingCharacters(in: .whitespaces).lowercased()
            if rangeSeparators.contains(separator), let last = letters.last, let from = last.unicodeScalars.first?.value,
               let to = lowered.unicodeScalars.first?.value, to > from, to - from < 26 {
                for value in (from + 1)...to {
                    if let scalar = Unicode.Scalar(value) { letters.append(String(Character(scalar))) }
                }
            } else {
                letters.append(lowered)
            }
            cursor = letterRange.upperBound
        }
        return letters
    }

    private static let rangeSeparators: Set<String> = ["–", "—", "-", "to", "through"]
    // Glued ("1a") or bracketed ("1(a)", "1 (a)"), a single letter with no
    // letter or digit after it.
    private static let firstPanel = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z])|\s*\(([A-Za-z])\))(?![A-Za-z0-9])"#
    )
    // ", b", " and b", " & b", "–c", "-c", " to c", ", and c", "(b)".
    private static let nextPanel = try! NSRegularExpression(
        pattern: #"^(\s*(?:,\s*(?:and|&)?|\s(?:and|&|to|through)|\s*[–—-])\s*)\(?([A-Za-z])\)?(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static func nextPanelContinues(_ rest: String, from index: String.Index) -> Bool {
        nextPanel.firstMatch(in: rest, range: NSRange(index..., in: rest)) != nil
    }

    /// A pattern matching a citation of the figure in running text — "Fig. 1",
    /// "Figure 1a", "Figs. 1a and c", "Extended Data Fig. 2" — and not the
    /// figure whose number merely begins with the same digits ("Figure 12")
    /// nor, for a main figure, the extended-data or supplementary figure of
    /// the same number. The match ends at the number, so what follows it can
    /// be read for panels. Nil when the label carries no number.
    static func mentionPattern(for label: String) -> String? {
        let canonical = PaperWalkthroughValidation.canonicalLabel(label)
        let words = canonical.split(separator: " ").map(String.init)
        guard let figureIndex = words.firstIndex(of: "figure"),
              figureIndex + 1 < words.count else { return nil }
        let number = words[figureIndex + 1]
        let digits = number.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let qualifier = words[..<figureIndex].joined(separator: " ")
        let figureWord = "(?:figs?\\.?|figures?)"
        if qualifier.isEmpty {
            // A bare "Figure 1": not "Extended Data Fig. 1" or "Supplementary Fig. 1".
            return "(?<!data\\s)(?<!supplementary\\s)(?<!supplemental\\s)\\b\(figureWord)\\s*\(digits)(?![0-9])"
        }
        let qualifierPattern = qualifier
            .split(separator: " ")
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        return "\\b\(qualifierPattern)\\s+\(figureWord)\\s*\(digits)(?![0-9])"
    }

    /// Whether a sentence is the figure's caption rather than a citation of
    /// it: it opens with the label — "Fig. 1 | Intracellular Na…", "Figure
    /// 1. Sleep in flies", "Figure 1 Sleep in flies" — and what follows the
    /// label is a separator, a capital or nothing. A body sentence opens
    /// with the label too ("Figure 2 shows the model", "Figs. 1 and 2
    /// summarise…") and goes on in lower case, and is kept.
    static func isCaption(_ sentence: String, canonical: String, firstMatch: NSTextCheckingResult) -> Bool {
        guard opensWithLabel(sentence, canonical: canonical),
              let matched = Range(firstMatch.range, in: sentence) else { return false }
        var rest = sentence[matched.upperBound...]
        // A glued panel letter ("Fig. 1a shows") is part of the citation.
        if let first = rest.first, first.isLetter, rest.dropFirst().first.map({ !$0.isLetter }) ?? true {
            rest = rest.dropFirst()
        }
        rest = rest.drop(while: { $0 == " " })
        guard let next = rest.first else { return true }
        return !(next.isLetter && next.isLowercase)
    }

    /// Whether a paragraph or sentence opens with the figure's label — "Fig.
    /// 1 | Intracellular Na…", "Figure 1. Sleep in flies" — the way a caption
    /// does. Both sides are canonicalised, so "Fig." and "Figure" agree, and
    /// the label must end where the next word begins, so "Figure 10" does
    /// not open with "figure 1".
    static func opensWithLabel(_ paragraph: String, canonical: String) -> Bool {
        let opening = paragraph
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .joined(separator: " ")
        let canonicalOpening = PaperWalkthroughValidation.canonicalLabel(opening)
        return canonicalOpening == canonical || canonicalOpening.hasPrefix(canonical + " ")
    }

    /// The text as it reads: soft hyphens and ligatures resolved, a word the
    /// column broke at a hyphen closed up (a hyphen before a capital or a
    /// digit stays: "Na+-ATPase"), every run of white space one space.
    static func readable(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\u{00AD}", with: "")
        value = value.replacingOccurrences(of: "\u{FB01}", with: "fi")
        value = value.replacingOccurrences(of: "\u{FB02}", with: "fl")
        value = value.replacingOccurrences(of: #"-[ \t]*\n[ \t]*(?=\p{Ll})"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"-[ \t]*\n[ \t]*"#, with: "-", options: .regularExpression)
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The text's sentences, readable. A sentence ends at a full stop,
    /// question or exclamation mark (closing brackets and quotes taken along)
    /// followed by a space and a capital, a digit or an opening bracket or
    /// quote — unless the stop closes an abbreviation a paper prints ("Fig.",
    /// "et al.", "e.g.", "vs.", "Eq.") or an initial ("J. Smith").
    static func sentences(in text: String) -> [String] {
        let characters = Array(readable(text))
        var sentences: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard character == "." || character == "!" || character == "?" else { continue }
            while index < characters.count, closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            guard index + 1 < characters.count, characters[index] == " " else { continue }
            let next = characters[index + 1]
            guard next.isUppercase || next.isNumber || openers.contains(next) else { continue }
            if character == ".", endsWithAbbreviation(current) { continue }
            sentences.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static let closers: Set<Character> = [")", "]", "\"", "'", "\u{201D}", "\u{2019}"]
    private static let openers: Set<Character> = ["(", "[", "\"", "\u{201C}", "\u{2018}"]
    /// Abbreviations a paper closes with a full stop mid-sentence.
    private static let abbreviations: Set<String> = [
        "fig", "figs", "ref", "refs", "eq", "eqs", "eqn", "eqns", "no", "nos", "vs", "cf", "ca", "al",
        "e.g", "i.e", "viz", "etc", "approx", "resp", "dr", "prof", "mr", "mrs", "ms", "st", "vol", "vols",
        "pp", "p", "chap", "ch", "sec", "suppl", "supp", "sp", "spp", "min", "max", "mol", "wt", "conc",
    ]

    /// Whether the text so far ends in an abbreviation's stop: its last word,
    /// stop and brackets removed, is one a paper abbreviates or dotted
    /// letters ("U.S."; "0.05" is a number, and closes a sentence); or it is
    /// an initial — a bare capital and its stop ("J. Doe") — unless the word
    /// before it makes it a panel in a list ("Figs. 1E and F.", "Fig. 1A,
    /// B.").
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let last = words.last else { return false }
        let raw = String(last)
        if raw.count == 2, raw.last == ".", let letter = raw.first, letter.isLetter, letter.isUppercase {
            let before = words.dropLast().last.map(String.init)?.lowercased() ?? ""
            let listed = ["and", "&", "to", "through"].contains(before) || before.hasSuffix(",")
            return !listed
        }
        var word = raw
        while let end = word.last, end == "." || closers.contains(end) { word.removeLast() }
        while let first = word.first, openers.contains(first) { word.removeFirst() }
        guard !word.isEmpty else { return false }
        if word.contains("."), !word.contains(where: \.isNumber) { return true }
        return abbreviations.contains(word.lowercased())
    }
}
