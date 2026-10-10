import Foundation

// MARK: - Memory as cards: the card face and its state
//
// docs/memory-design.md, "Cards: identity and Keep". A kept card is a
// `MemoryItem` written once, at Keep, and never changed after: the item's
// curriculum fingerprint covers its target, rubric, goal and anchors
// (`MemoryTutorIdentity.immutableCurriculumFingerprint`), so a changed item
// would be archived as a conflict on the learner's other devices. The card's
// face rides inside the item:
//
// - `target` is the back;
// - `rubricJSON` is `{"card":{"cardID","deckID"?,"difficulty"?,"front","origin"},
//   "criteria":[why…]}`, written by `rubricJSON()` alone, keys sorted, because
//   the fingerprint compares bytes;
// - the anchor is the card's quote, verified against the source's text.
//
// What the learner changes about a card after Keep (an edited front, its
// variants, "always ask it this way", whether a draft was kept or skipped)
// lives in one synced preference row per deck, `cards.state.<deckID>`
// (`MemoryCardDeckState`), never in the item. Editing a kept card's back or
// why is "Start this card over?": the item is retired and a revision with a
// new card id is kept (`KnowledgeStore.startMemoryCardOver`).
//
// Compiled into the iPhone app too (project.yml), which reads the same faces
// and rows. Foundation only.

/// Where a kept card came from, as its rubric records it. A value this build
/// does not know reads as itself, so a card a newer device kept still shows.
struct MemoryCardOrigin: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Drafted from a source by ForeverLM, and kept by the learner.
    static let drafted = MemoryCardOrigin(rawValue: "drafted")
    /// Drafted by an assistant or the voice tutor, and kept by the learner.
    static let assistant = MemoryCardOrigin(rawValue: "assistant")
    /// A walkthrough question the learner marked Forgot, or found only on the
    /// second try: kept when it was missed, with no draft to go through.
    static let walkthrough = MemoryCardOrigin(rawValue: "walkthrough")
    /// A course-quiz question graded incorrect or partial: kept the same way.
    static let courseQuiz = MemoryCardOrigin(rawValue: "course_quiz")
    /// An item from before cards, read as a card (`MemoryCard.legacyFace`).
    /// Never written: such an item keeps the rubric it was made with.
    static let legacy = MemoryCardOrigin(rawValue: "legacy")
}

/// How hard a card was drafted to be. Optional on every card; a value this
/// build does not know reads as none.
enum MemoryCardDifficulty: String, CaseIterable, Sendable {
    case easy
    case medium
    case hard
}

/// One durable picture on a card face. The target is a ForeverLM source
/// picture or generated picture address, never a local path or web URL, so
/// the card can carry the same reference to every client. Alt text is stored
/// with it for accessibility and for a useful unavailable-picture note.
struct MemoryCardImage: Equatable, Hashable, Sendable {
    let target: String
    let alt: String

    init?(target: String, alt: String = "Image") {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SourceImageReference(urlString: target) != nil
                || GeneratedImageReference(urlString: target) != nil else { return nil }
        self.target = target
        self.alt = Self.cleanAlt(alt)
    }

    /// Accepts the exact Markdown line returned by ForeverLM's image tools,
    /// or its bare `foreverlm://image/…` address.
    init?(reference: String) {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("!["), let close = value.range(of: "]("), value.hasSuffix(")") {
            let alt = String(value[value.index(value.startIndex, offsetBy: 2)..<close.lowerBound])
            let target = String(value[close.upperBound..<value.index(before: value.endIndex)])
            self.init(target: target, alt: alt)
        } else {
            self.init(target: value)
        }
    }

    var markdown: String { "![\(Self.cleanAlt(alt))](\(target))" }

    var rubricObject: [String: String] { ["target": target, "alt": alt] }

    static func readRubric(_ value: Any?) -> [MemoryCardImage] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let target = entry["target"] as? String else { return nil }
            return MemoryCardImage(target: target, alt: entry["alt"] as? String ?? "Image")
        }
    }

    private static func cleanAlt(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Image" : cleaned
    }
}

/// One card's face: what is asked, what answers it, and why that is right.
struct MemoryCard: Equatable, Sendable, Identifiable {
    /// The card's identity. A drafted card's is minted when it is drafted (a
    /// UUID) and names its item (`MemoryTutorIdentity.cardItemID`); a card
    /// kept when it was missed, and an item from before cards, has its item's
    /// own id, which every device derives alike.
    let cardID: String
    /// The wording the card was kept with. The learner's own rewording, when
    /// there is one, is in the card's state (`MemoryCardState.editedFront`).
    let front: String
    let back: String
    /// Why the back is right: a drafted card's why line, or a quiz question's
    /// key points. Empty when there is none; a why that only repeats the back
    /// is none.
    let why: [String]
    let origin: MemoryCardOrigin
    let difficulty: MemoryCardDifficulty?
    /// Pictures shown with the question, before reveal.
    let frontImages: [MemoryCardImage]
    /// Pictures shown with the answer, after reveal. Two or more share a row.
    let backImages: [MemoryCardImage]
    /// The draft deck the card was kept from (`draftDeckID(sourceID:)`); nil
    /// for a card kept when it was missed and for an item from before cards.
    let deckID: String?

    var id: String { cardID }

    init(
        cardID: String,
        front: String,
        back: String,
        why: [String] = [],
        origin: MemoryCardOrigin,
        difficulty: MemoryCardDifficulty? = nil,
        deckID: String? = nil,
        frontImages: [MemoryCardImage] = [],
        backImages: [MemoryCardImage] = []
    ) {
        let back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasons = why
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.cardID = cardID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        self.back = back
        self.why = reasons == [back] ? [] : reasons
        self.origin = origin
        self.difficulty = difficulty
        self.frontImages = Array(frontImages.prefix(Self.maximumImagesPerFace))
        self.backImages = Array(backImages.prefix(Self.maximumImagesPerFace))
        let deck = deckID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deckID = deck?.isEmpty == false ? deck : nil
    }

    /// The fixed id of a source's draft deck: one per source, the same on
    /// every Mac, so two Macs drafting for one source write one deck.
    static func draftDeckID(sourceID: String) -> String {
        draftDeckIDPrefix + sourceID
    }

    static let draftDeckIDPrefix = "carddeck-"
    static let maximumImagesPerFace = 4

    /// Whether `id` names a source's draft deck. The id is the deck's own
    /// mark, so a deck an older build saved back without its kind is still
    /// one (`ArtifactRecord.isCardDeck`).
    static func isDraftDeckID(_ id: String) -> Bool {
        id.hasPrefix(draftDeckIDPrefix)
    }

    /// The source a draft deck's id names; nil for any other id.
    static func sourceID(fromDraftDeckID id: String) -> String? {
        guard isDraftDeckID(id) else { return nil }
        let sourceID = String(id.dropFirst(draftDeckIDPrefix.count))
        return sourceID.isEmpty ? nil : sourceID
    }

    /// The deck whose `cards.state.<deckID>` row holds this card's state: the
    /// deck it was kept from, or else the draft deck of the source its item is
    /// anchored on. Nil only for an item with no anchor, which storage never
    /// keeps.
    func stateDeckID(in item: MemoryItem) -> String? {
        if let deckID { return deckID }
        let anchor = item.sources.min {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id < $1.id
        }
        return anchor.map { Self.draftDeckID(sourceID: $0.sourceID) }
    }

    /// The card's own wording: the learner's rewording when they made one,
    /// otherwise the front it was kept with. A card remembered twice may be
    /// asked in one of its variants instead (`MemoryCardWording.asked`, on
    /// the Mac); this is the wording a variant rewords, and the one asked
    /// when there is none.
    func wording(state: MemoryCardState?) -> String {
        if let edited = state?.editedFront?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty {
            return edited
        }
        return front
    }

    /// What the card's item is graded by: its why, or its back when it has none.
    var criteria: [String] {
        why.isEmpty ? [back] : why
    }

    // MARK: Writing the item

    /// The item's `rubricJSON`. The one writer of a card rubric: the same card
    /// always gives the same bytes, so two devices keeping the same card agree
    /// on its curriculum.
    func rubricJSON() throws -> String {
        var card: [String: Any] = [
            Self.cardIDKey: cardID,
            Self.frontKey: front,
            Self.originKey: origin.rawValue,
        ]
        if let difficulty { card[Self.difficultyKey] = difficulty.rawValue }
        if let deckID { card[Self.deckIDKey] = deckID }
        if !frontImages.isEmpty { card[Self.frontImagesKey] = frontImages.map(\.rubricObject) }
        if !backImages.isEmpty { card[Self.backImagesKey] = backImages.map(\.rubricObject) }
        let rubric: [String: Any] = [Self.cardKey: card, Self.criteriaKey: criteria]
        let data = try JSONSerialization.data(withJSONObject: rubric, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw MemoryCardError.unwritable(cardID)
        }
        return json
    }

    /// The Memory item this card is kept as, anchored on the passages
    /// `anchors` verified (`KnowledgeStore.validatedMemorySourceAnchor`), best
    /// first. `id` is `MemoryTutorIdentity.cardItemID(cardID:)` for a drafted
    /// card and the question's item id for one kept when it was missed.
    func memoryItem(
        id: String,
        anchors: [MemorySourceAnchorValidation],
        goalID: String? = nil,
        ideaID: String? = nil,
        at now: Date
    ) throws -> MemoryItem {
        guard origin != .legacy else { throw MemoryCardError.legacyCard(cardID) }
        guard !cardID.isEmpty, !front.isEmpty, !back.isEmpty else {
            throw MemoryCardError.incomplete(cardID)
        }
        guard !anchors.isEmpty else { throw MemoryCardError.unanchored(cardID) }
        return MemoryItem(
            id: id,
            kind: .concept,
            target: back,
            rubricJSON: try rubricJSON(),
            goalID: goalID,
            sources: anchors.enumerated().map { index, anchor in
                MemoryItemSource(
                    id: MemoryTutorIdentity.firstReviewAnchorID(memoryItemID: id, sortIndex: index),
                    memoryItemID: id,
                    sourceID: anchor.sourceID,
                    excerpt: anchor.excerpt,
                    sourceSHA256: anchor.sourceSHA256,
                    sortIndex: index
                )
            },
            createdAt: now,
            updatedAt: now,
            ideaID: ideaID
        )
    }

    // MARK: Reading an item

    /// The card a kept item carries in `rubricJSON.card`, with its back from
    /// the item's target. Nil for an item without one: an item from before
    /// cards (read it with `legacyFace`), or a first-review target.
    init?(storedIn item: MemoryItem) {
        guard let rubric = Self.rubricObject(item.rubricJSON),
              let card = rubric[Self.cardKey] as? [String: Any],
              let cardID = card[Self.cardIDKey] as? String,
              let front = card[Self.frontKey] as? String,
              let origin = card[Self.originKey] as? String else { return nil }
        self.init(
            cardID: cardID,
            front: front,
            back: item.target,
            why: Self.criteria(in: rubric),
            origin: MemoryCardOrigin(rawValue: origin),
            difficulty: (card[Self.difficultyKey] as? String).flatMap(MemoryCardDifficulty.init(rawValue:)),
            deckID: card[Self.deckIDKey] as? String,
            frontImages: MemoryCardImage.readRubric(card[Self.frontImagesKey]),
            backImages: MemoryCardImage.readRubric(card[Self.backImagesKey])
        )
        guard !self.cardID.isEmpty, !self.front.isEmpty, !self.back.isEmpty else { return nil }
    }

    /// What any item shows as a card: the card it carries, or else its
    /// reading as one (`legacyFace`). Nil when neither gives a front and a back.
    static func face(of item: MemoryItem, attempts: [MemoryAttempt]) -> MemoryCard? {
        MemoryCard(storedIn: item) ?? legacyFace(of: item, attempts: attempts)
    }

    /// An item from before cards read as one, from what its writer stored. The
    /// walkthrough and course-quiz writer stored `"<question> — <answer>"` cut
    /// at 1,000 characters as the target, the key points (or the answer) as
    /// the criteria, and the question as its first attempt's prompt:
    ///
    /// - the front is the earliest attempt's prompt;
    /// - the back is the target less exactly that prompt and " — ", and the
    ///   whole target when it does not start so (a first-review target, which
    ///   is what to recall);
    /// - a target of exactly 1,000 characters was cut, so its back is the
    ///   criteria instead, which the writer stored whole;
    /// - an item no attempt has reached yet is split at its first " — ", the
    ///   writer's own separator, and has no face when it has none.
    ///
    /// The card id is the item's id, and the origin `.legacy`.
    static func legacyFace(of item: MemoryItem, attempts: [MemoryAttempt]) -> MemoryCard? {
        let stored = criteria(in: rubricObject(item.rubricJSON) ?? [:])
        let earliestPrompt = attempts
            .filter { $0.memoryItemID == item.id && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .min {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }?
            .prompt
        let front: String
        let rest: String
        if let earliestPrompt {
            front = earliestPrompt
            let prefix = earliestPrompt + legacySeparator
            rest = item.target.hasPrefix(prefix) ? String(item.target.dropFirst(prefix.count)) : item.target
        } else if let separator = item.target.range(of: legacySeparator) {
            front = String(item.target[..<separator.lowerBound])
            rest = String(item.target[separator.upperBound...])
        } else {
            return nil
        }
        let wasCut = item.target.count == legacyTargetLimit && !stored.isEmpty
        let card = MemoryCard(
            cardID: item.id,
            front: front,
            back: wasCut ? stored.joined(separator: "\n") : rest,
            why: wasCut ? [] : stored,
            origin: .legacy
        )
        guard !card.front.isEmpty, !card.back.isEmpty else { return nil }
        return card
    }

    /// What the writer before cards put between a question and its answer.
    static let legacySeparator = " — "
    /// Where that writer cut its target.
    static let legacyTargetLimit = 1_000

    // MARK: Rubric keys

    static let cardKey = "card"
    static let criteriaKey = "criteria"
    static let cardIDKey = "cardID"
    static let frontKey = "front"
    static let originKey = "origin"
    static let difficultyKey = "difficulty"
    static let deckIDKey = "deckID"
    static let frontImagesKey = "frontImages"
    static let backImagesKey = "backImages"

    private static func rubricObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func criteria(in rubric: [String: Any]) -> [String] {
        ((rubric[criteriaKey] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum MemoryCardError: LocalizedError, Equatable {
    case unwritable(String)
    case incomplete(String)
    case unanchored(String)
    case legacyCard(String)

    var errorDescription: String? {
        switch self {
        case .unwritable(let cardID):
            return "Card \(cardID)'s rubric could not be written."
        case .incomplete(let cardID):
            return "Card \(cardID) needs an id, a front and a back to be kept."
        case .unanchored(let cardID):
            return "Card \(cardID) quotes no passage its source prints, so it cannot be kept."
        case .legacyCard(let cardID):
            return "Card \(cardID) is an item from before cards; it is kept as it is, not written again."
        }
    }
}

// MARK: - Self-graded answers

extension MemoryAttempt {
    /// What a self-graded attempt records as the learner's answer: they
    /// looked at the back and said whether they had it.
    static let selfGradedAnswer = "(self-graded)"

    /// A card the learner graded themselves after seeing its back: graded, with
    /// no model, no chat and so no session or exchange; Remembered is score 1
    /// and `good`, Forgot score 0 and `again`. `prompt` is the wording the card
    /// was asked in (`MemoryCard.wording(state:)`). `id` is the caller's; the
    /// Mac's store derives it from the sitting and the card
    /// (`MemoryTutorIdentity.selfGradedAttemptID`).
    static func selfGraded(
        id: String,
        memoryItemID: String,
        prompt: String,
        remembered: Bool,
        at attemptedAt: Date
    ) -> MemoryAttempt {
        MemoryAttempt(
            id: id,
            memoryItemID: memoryItemID,
            attemptType: .review,
            prompt: prompt,
            learnerAnswer: selfGradedAnswer,
            score: remembered ? 1 : 0,
            scheduleRating: remembered ? .good : .again,
            gradeState: .graded,
            attemptedAt: attemptedAt
        )
    }
}

/// What became of a self-graded answer
/// (`KnowledgeStore.recordSelfGradedMemoryCardAttempt`). Only `.recorded`
/// wrote anything; the others are answers the review shows and keeps no trace
/// of.
enum MemoryCardAnswerOutcome: String, Equatable, Sendable {
    /// Written as an attempt: the card's schedule moved.
    case recorded
    /// This sitting already wrote an answer to this card: a "Review forgotten"
    /// repeat, or the same answer sent twice.
    case alreadyRecorded
    /// The card is neither due nor new and eligible (in practice: a card seen
    /// before and not yet due), so the answer does not count
    /// (`MemoryCardQueue.answerCounts`).
    case notCounted
    /// The card is retired.
    case retired
}

// MARK: - A card's state: `cards.state.<deckID>`

/// Where a card stands with the learner.
enum MemoryCardStatus: String, CaseIterable, Sendable {
    /// Drafted, not yet gone through.
    case draft
    /// Kept: its Memory item exists (`MemoryCardState.memoryItemID`).
    case kept
    /// Gone through and not wanted. A seed skipped once is never offered again.
    case skipped
}

/// What the learner changed about one card, outside its item.
struct MemoryCardState: Equatable, Sendable {
    var status: MemoryCardStatus
    /// The kept card's Memory item.
    var memoryItemID: String?
    /// The learner's own wording of the front, asked instead of the front the
    /// card was kept with (`MemoryCard.wording(state:)`).
    var editedFront: String?
    /// Rewordings that ask for the same back, in the order they were made.
    var variants: [String]
    /// Variants taken out of the rotation, by their words.
    var retiredVariants: [String]
    /// Ask the card in one wording every time, never a variant.
    var alwaysAsk: Bool
    /// What the draft was made from (a walk step, a highlight, an idea or
    /// guide question's hash), so drafting never offers the same seed twice.
    var seed: String?
    /// When the day close reworded the card, once it was remembered twice
    /// (`CardVariationPass`): set once, whether or not any rewording passed
    /// its checks, so a card is reworded — and billed — once.
    var variedAt: Date?
    var updatedAt: Date

    init(
        status: MemoryCardStatus,
        memoryItemID: String? = nil,
        editedFront: String? = nil,
        variants: [String] = [],
        retiredVariants: [String] = [],
        alwaysAsk: Bool = false,
        seed: String? = nil,
        variedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.status = status
        self.memoryItemID = memoryItemID
        self.editedFront = editedFront
        self.variants = variants
        self.retiredVariants = retiredVariants
        self.alwaysAsk = alwaysAsk
        self.seed = seed
        self.variedAt = variedAt
        self.updatedAt = updatedAt
    }

    /// Two devices' copies of one card as one: a kept card stays kept, since
    /// its item exists whatever the other device later said; otherwise the
    /// newer copy wins whole, and two copies stamped alike resolve the same
    /// way on every device.
    static func merged(_ lhs: MemoryCardState, _ rhs: MemoryCardState) -> MemoryCardState {
        let lhsKept = lhs.status == .kept
        if lhsKept != (rhs.status == .kept) { return lhsKept ? lhs : rhs }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        return lhs.tieKey >= rhs.tieKey ? lhs : rhs
    }

    private var tieKey: String {
        [
            status.rawValue,
            memoryItemID ?? "",
            editedFront ?? "",
            variants.joined(separator: "\u{1}"),
            retiredVariants.joined(separator: "\u{1}"),
            alwaysAsk ? "1" : "0",
            seed ?? "",
            variedAt.map { String($0.timeIntervalSince1970) } ?? "",
        ].joined(separator: "\u{0}")
    }

    // Property-list keys of one card's entry.
    fileprivate static let statusKey = "status"
    fileprivate static let memoryItemKey = "item"
    fileprivate static let frontKey = "front"
    fileprivate static let variantsKey = "variants"
    fileprivate static let retiredKey = "retired"
    fileprivate static let alwaysAskKey = "alwaysAsk"
    fileprivate static let seedKey = "seed"
    fileprivate static let variedAtKey = "varied"
    fileprivate static let updatedAtKey = "t"

    fileprivate var preferenceValue: [String: Any] {
        var value: [String: Any] = [
            Self.statusKey: status.rawValue,
            Self.variantsKey: variants,
            Self.retiredKey: retiredVariants,
            Self.alwaysAskKey: alwaysAsk,
            Self.updatedAtKey: updatedAt.timeIntervalSince1970,
        ]
        if let memoryItemID { value[Self.memoryItemKey] = memoryItemID }
        if let editedFront { value[Self.frontKey] = editedFront }
        if let seed { value[Self.seedKey] = seed }
        if let variedAt { value[Self.variedAtKey] = variedAt.timeIntervalSince1970 }
        return value
    }

    fileprivate init?(preferenceValue value: Any) {
        guard let entry = value as? [String: Any],
              let status = (entry[Self.statusKey] as? String).flatMap(MemoryCardStatus.init(rawValue:)),
              let time = (entry[Self.updatedAtKey] as? NSNumber)?.doubleValue, time.isFinite else { return nil }
        self.init(
            status: status,
            memoryItemID: entry[Self.memoryItemKey] as? String,
            editedFront: entry[Self.frontKey] as? String,
            variants: (entry[Self.variantsKey] as? [String]) ?? [],
            retiredVariants: (entry[Self.retiredKey] as? [String]) ?? [],
            alwaysAsk: (entry[Self.alwaysAskKey] as? Bool) ?? false,
            seed: entry[Self.seedKey] as? String,
            variedAt: (entry[Self.variedAtKey] as? NSNumber).map(\.doubleValue).flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            },
            updatedAt: Date(timeIntervalSince1970: time)
        )
    }
}

/// One deck's card states: the synced preference row `cards.state.<deckID>`,
/// a property-list dictionary the Mac and the phone both read and write. Per
/// learner, in the private database: never in a team record, so a team's copy
/// of a notebook carries no member's cards (docs/teams-design.md rule 7).
///
/// The row syncs whole and the last write wins, so every writer reads the
/// stored row, merges its own copy in card by card (`merged(with:)`), applies
/// its change and writes the result (`updating`), and a device receiving the
/// row merges it with its own and sends the merge back when it differs
/// (`mergedOnReceipt`, applied by `PreferenceStore.applyInbound`). It is
/// written only when the learner does something to a card: never when cards
/// are shown, and never while a lock is held (a defaults write posts a
/// notification on the writing thread).
struct MemoryCardDeckState: Equatable, Sendable {
    static let preferenceKeyPrefix = "cards.state."

    /// Card states by card id.
    var cards: [String: MemoryCardState]

    init(cards: [String: MemoryCardState] = [:]) {
        self.cards = cards
    }

    static func preferenceKey(deckID: String) -> String {
        preferenceKeyPrefix + deckID
    }

    static func deckID(fromPreferenceKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let deckID = String(key.dropFirst(preferenceKeyPrefix.count))
        return deckID.isEmpty ? nil : deckID
    }

    /// Two copies of the row as one, card by card (`MemoryCardState.merged`).
    func merged(with other: MemoryCardDeckState) -> MemoryCardDeckState {
        var cards = self.cards
        for (cardID, theirs) in other.cards {
            if let mine = cards[cardID] {
                cards[cardID] = MemoryCardState.merged(mine, theirs)
            } else {
                cards[cardID] = theirs
            }
        }
        return MemoryCardDeckState(cards: cards)
    }

    /// Marks a card kept as `memoryItemID`, keeping what else its state holds
    /// (its seed above all); `seed` is the one its draft was made from, when
    /// the state holds none yet.
    mutating func markKept(cardID: String, memoryItemID: String, seed: String? = nil, at now: Date) {
        var state = cards[cardID] ?? MemoryCardState(status: .kept, updatedAt: now)
        state.status = .kept
        state.memoryItemID = memoryItemID
        if state.seed == nil { state.seed = seed }
        state.updatedAt = now
        cards[cardID] = state
    }

    /// Marks a card skipped: gone through and not wanted, so it leaves the
    /// cards to check and its seed is never drafted again. A kept card stays
    /// kept — its item exists — and is retired, not skipped.
    mutating func markSkipped(cardID: String, seed: String? = nil, at now: Date) {
        var state = cards[cardID] ?? MemoryCardState(status: .skipped, updatedAt: now)
        guard state.status != .kept else { return }
        state.status = .skipped
        if state.seed == nil { state.seed = seed }
        state.updatedAt = now
        cards[cardID] = state
    }

    /// A card started over (`KnowledgeStore.startMemoryCardOver`): the new
    /// revision is kept as `newMemoryItemID` with the old card's seed and
    /// "always ask it this way". Its rewording and variants asked for the old
    /// back, so they stay with the old card, which stays kept on its retired
    /// item.
    mutating func recordStartOver(
        from oldCardID: String,
        to newCardID: String,
        newMemoryItemID: String,
        at now: Date
    ) {
        let old = cards[oldCardID]
        cards[newCardID] = MemoryCardState(
            status: .kept,
            memoryItemID: newMemoryItemID,
            alwaysAsk: old?.alwaysAsk ?? false,
            seed: old?.seed,
            updatedAt: now
        )
    }

    /// The row's value: `["cards": [cardID: ["status":, "item":?, "front":?,
    /// "variants":, "retired":, "alwaysAsk":, "seed":?, "varied":? and "t":
    /// unix seconds]]]`.
    var preferenceValue: [String: Any] {
        ["cards": cards.mapValues(\.preferenceValue)]
    }

    /// Reads a row back; nil for anything that is not one. A card entry this
    /// build cannot read is left out.
    init?(preferenceValue value: Any) {
        guard let dictionary = value as? [String: Any],
              let entries = dictionary["cards"] as? [String: Any] else { return nil }
        var cards: [String: MemoryCardState] = [:]
        for (cardID, entry) in entries where !cardID.isEmpty {
            if let state = MemoryCardState(preferenceValue: entry) {
                cards[cardID] = state
            }
        }
        self.init(cards: cards)
    }

    /// The other device's copy of a row, arriving through sync, against this
    /// device's. Rows sync whole and the last write wins, so two devices that
    /// changed different cards before syncing would each lose the other's
    /// change. Merged on receipt card by card, both stay. Returns the merged
    /// row when it holds something the incoming one lacks: the receiver keeps
    /// it and sends it back. Nil when the incoming row already holds
    /// everything, or either value is not a row: the incoming value stands.
    /// The merge is idempotent, commutative and associative, so the other
    /// device's merge of the row sent back equals what it receives, and the
    /// exchange settles after one round. As in `updating`, an entry this build
    /// cannot read is left out of a row it writes.
    static func mergedOnReceipt(incoming: Any, local: Any?) -> [String: Any]? {
        guard let incomingRow = MemoryCardDeckState(preferenceValue: incoming),
              let local,
              let localRow = MemoryCardDeckState(preferenceValue: local) else { return nil }
        let merged = localRow.merged(with: incomingRow)
        return merged == incomingRow ? nil : merged.preferenceValue
    }

    /// Read, merge, write. `read` gives the stored row (the defaults value,
    /// remote writes included); `local` is the caller's own copy, when it
    /// keeps one; `change` is applied to the two merged; `write` stores the
    /// result under the row's key, and is the caller's synced write
    /// (`PreferenceStore.set` on the Mac). Returns the row as written.
    static func updating(
        deckID: String,
        local: MemoryCardDeckState? = nil,
        read: (String) -> Any?,
        write: (Any, String) -> Void,
        _ change: (inout MemoryCardDeckState) -> Void
    ) -> MemoryCardDeckState {
        let key = preferenceKey(deckID: deckID)
        let stored = read(key).flatMap(MemoryCardDeckState.init(preferenceValue:))
        var state: MemoryCardDeckState
        switch (local, stored) {
        case let (local?, stored?): state = local.merged(with: stored)
        case let (local?, nil): state = local
        case let (nil, stored?): state = stored
        case (nil, nil): state = MemoryCardDeckState()
        }
        change(&state)
        write(state.preferenceValue, key)
        return state
    }
}
