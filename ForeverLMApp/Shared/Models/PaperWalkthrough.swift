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
