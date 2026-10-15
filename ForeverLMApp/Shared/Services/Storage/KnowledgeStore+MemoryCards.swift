import CryptoKit
import Foundation

// MARK: - Memory as cards: keeping, retiring and starting over
//
// docs/memory-design.md, "Cards: identity and Keep". A kept card is a Memory
// item written once, at Keep (`MemoryCard`); afterwards only its status
// changes. The card's mutable state is its deck's state
// (`MemoryCardStateStore`: the Card rows under generation 2, the
// `cards.state.<deckID>` preference row under generation 1), which callers
// update after these succeed. Under generation 2 a card's item is its Card's
// own id, so these also say on the Card what they did (`KnowledgeStore+CardRecords`).

/// A question the learner was asked about a source, as the Memory item a miss
/// on it becomes: the question, its answer and key points, where it was
/// asked, and the source passages that may ground it, best first — the first
/// one the source's text prints being the item's anchor. Walkthrough question
/// cards and course-quiz questions are both written through it
/// (`KnowledgeStore.recordSourceQuestionAttempt`).
///
/// For a walkthrough question the passages are the authors' sentence the step
/// is about, then the step's own anchor passage, then the same of each step it
/// follows in its chapter, nearest first. Until 2026-09-30 only the question
/// step's own passages counted, and a question step rarely has one: the
/// writer leaves a question unanchored so the Reader does not mark its
/// answer. None of the 20 questions of the "Metabolism as inference" walk and
/// only 1 of the 10 of "Engineered human resilience and durability" could be
/// grounded, so a Forgot on the others threw and the miss never came back in
/// spaced review.
struct SourceMemoryQuestion: Equatable, Sendable {
    let sourceID: String
    let stepID: String
    let question: String
    let answer: String
    let keyPoints: [String]
    let excerpts: [String]
    /// Where the question was asked, which its card records.
    let origin: MemoryCardOrigin

    /// A walkthrough's question card. `testing` is the steps the question
    /// follows, nearest first (`PaperWalkthrough.stepsBefore(question:)`).
    init(sourceID: String, step: PaperWalkthroughStep, quiz: PaperWalkthroughQuiz, testing: [PaperWalkthroughStep] = []) {
        self.sourceID = sourceID
        self.stepID = step.id
        self.question = quiz.question
        self.answer = quiz.answer
        self.keyPoints = quiz.keyPoints
        self.excerpts = ([step] + testing)
            .flatMap { [$0.sourceMention, $0.anchor?.passage] }
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.origin = .walkthrough
    }

    /// A question asked outside a walkthrough — a course quiz's — with
    /// `stepID` naming where it was asked (`course-quiz-<quiz>-<question>`)
    /// and `excerpts` the source passages it may be grounded in, best first.
    init(
        sourceID: String,
        stepID: String,
        question: String,
        answer: String,
        keyPoints: [String],
        excerpts: [String],
        origin: MemoryCardOrigin
    ) {
        self.sourceID = sourceID
        self.stepID = stepID
        self.question = question
        self.answer = answer
        self.keyPoints = keyPoints
        self.excerpts = excerpts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.origin = origin
    }

    /// The card a miss on this question keeps, under its item's id: the
    /// question is the front, the answer the back (the key points, written out,
    /// for a question stored without an answer), the key points the why.
    func card(itemID: String) -> MemoryCard {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = keyPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return MemoryCard(
            cardID: itemID,
            front: question,
            back: answer.isEmpty ? points.joined(separator: "\n") : answer,
            why: answer.isEmpty ? [] : points,
            origin: origin
        )
    }
}

extension KnowledgeStore {

    // MARK: Questions missed on a source: pre-kept cards

    /// A graded question about a source, as an attempt on the question's Memory
    /// item, so a question missed comes back in spaced review. A miss the
    /// learner just met is a kept card at once, with no draft to go through:
    /// the item is made only when the question did not come back (Forgot, a
    /// Find it that needed a second try, a course-quiz answer graded incorrect
    /// or partial), anchored to the first of the question's passages the
    /// source prints, and carries its card face (`SourceMemoryQuestion.card`,
    /// `rubricJSON.card`). A question remembered first time leaves nothing
    /// behind, and one remembered later advances its item. Throws, and saves
    /// nothing, when none of its passages is in the source's text: Memory never
    /// keeps an item it cannot ground. A new item and its first attempt (a
    /// `.discovery`) are written in one transaction, so the item is never left
    /// without the answer that made it.
    ///
    /// The item's id is still `MemoryTutorIdentity.walkthroughQuestionItemID`,
    /// the namespace the items from before cards were made under, so a
    /// question missed again finds its item.
    func recordSourceQuestionAttempt(
        _ question: SourceMemoryQuestion,
        answer: String,
        feedback: String,
        score: Double,
        rating: MemoryScheduleRating,
        at now: Date = Date()
    ) throws {
        var validation: MemorySourceAnchorValidation?
        for excerpt in question.excerpts {
            if let found = try? validatedMemorySourceAnchor(sourceID: question.sourceID, excerpt: excerpt) {
                validation = found
                break
            }
        }
        guard let validation else {
            throw KnowledgeStoreError.invalidData(
                "Question \(question.stepID) quotes no passage source \(question.sourceID) prints, so it has no Memory anchor."
            )
        }
        let itemID = MemoryTutorIdentity.walkthroughQuestionItemID(
            portableSourceKey: validation.portableSourceKey,
            stepID: question.stepID,
            question: question.question
        )
        let existing = try loadMemoryItem(itemID)
        if existing == nil, rating == .good || rating == .easy { return }
        let attempt = MemoryAttempt(
            id: UUID().uuidString,
            memoryItemID: itemID,
            attemptType: existing == nil ? .discovery : .review,
            prompt: question.question,
            learnerAnswer: answer,
            feedback: feedback,
            score: score,
            scheduleRating: rating,
            gradeState: .graded,
            attemptedAt: now
        )
        guard existing == nil else {
            _ = try recordMemoryAttempt(attempt)
            return
        }
        let item: MemoryItem
        do {
            item = try question.card(itemID: itemID).memoryItem(id: itemID, anchors: [validation], at: now)
        } catch let error as MemoryCardError {
            throw KnowledgeStoreError.invalidData(
                "Question \(question.stepID) cannot be kept as a card: \(error.localizedDescription)"
            )
        }
        try saveMemoryItemIfAbsent(item, recording: attempt)
    }

    // MARK: Keep

    /// Keeps a drafted card: makes its Memory item, once, anchored on `quote`,
    /// which the source's text must print, and on each passage of `alsoFrom`,
    /// which its own source's text must print too: a card that stands on
    /// several sources is anchored on all of them, the card's own source
    /// first. A passage of the card's own source is no second anchor. The item's id is the card's
    /// (`MemoryTutorIdentity.cardItemID`; under generation 2 the draft's Card
    /// id itself, so the Card the draft was is the card kept, and it says
    /// `kept` at once), so keeping it again — a second click, the other Mac —
    /// does nothing and returns the item already kept. A retired Card is never
    /// kept again.
    /// A different face under a card already kept throws: a kept card's back
    /// changes only by starting it over (`startMemoryCardOver`). Throws, and
    /// saves nothing, when the quote is not in the source's text.
    ///
    /// The card is new until its first answer, first asked the day after it
    /// was kept (`MemoryTutorScheduler.firstEligibleAt`). `ideaID` is the
    /// source idea it was drafted from. The item has no `goalID`: the goal is
    /// part of the item's curriculum fingerprint, so two Macs keeping the same
    /// card from two notebooks before syncing would disagree on it and send one
    /// copy to the conflict archive. A notebook reaches its cards through the
    /// sources they are anchored on. The item is inserted only when absent,
    /// inside the transaction (`saveMemoryItemIfAbsent`), so a keep racing
    /// another never overwrites it. The caller then marks the card kept in its
    /// deck's row (`MemoryCardDeckState.markKept`).
    @discardableResult
    func keepMemoryCard(
        _ card: MemoryCard,
        sourceID: String,
        quote: String,
        alsoFrom: [CardSourceLink] = [],
        ideaID: String? = nil,
        at now: Date = Date()
    ) throws -> MemoryItem {
        guard card.origin != .legacy else {
            throw KnowledgeStoreError.invalidData(MemoryCardError.legacyCard(card.cardID).localizedDescription)
        }
        let records = try recordsMemoryForGeneration2()
        let itemID = records ? card.cardID : MemoryTutorIdentity.cardItemID(cardID: card.cardID)
        if let existing = try loadMemoryItem(itemID) {
            return try keptAlready(existing, as: card)
        }
        if records, try cardRecordIsRetired(itemID) {
            throw KnowledgeStoreError.invalidData("Card \(card.cardID) is retired, so it is not kept again.")
        }
        let anchor = try validatedMemorySourceAnchor(sourceID: sourceID, excerpt: quote)
        var anchors = [anchor]
        for link in CardSourceLink.normalized(alsoFrom, excluding: CardSourceLink(sourceID: sourceID, quote: quote)) {
            anchors.append(try validatedMemorySourceAnchor(sourceID: link.sourceID, excerpt: link.quote))
        }
        let item: MemoryItem
        do {
            item = try card.memoryItem(id: itemID, anchors: anchors, goalID: nil, ideaID: ideaID, at: now)
        } catch let error as MemoryCardError {
            throw KnowledgeStoreError.invalidData(error.localizedDescription)
        }
        if let existing = try saveMemoryItemIfAbsent(item) {
            return try keptAlready(existing, as: card)
        }
        if records { try markCardRecordKept(itemID) }
        return item
    }

    /// A card kept already: the item, when it carries this face; otherwise
    /// the keep is refused, since a kept card's back changes only by starting
    /// it over.
    private func keptAlready(_ existing: MemoryItem, as card: MemoryCard) throws -> MemoryItem {
        guard MemoryCard(storedIn: existing) == card else {
            throw KnowledgeStoreError.invalidData(
                "Card \(card.cardID) is kept already with another face; start it over to change its answer."
            )
        }
        return existing
    }

    // MARK: Retire

    /// Retires a card: its item stays, with its attempts, and is never asked
    /// again. Retiring a retired card does nothing.
    func retireMemoryCard(memoryItemID: String, at now: Date = Date()) throws {
        guard let item = try loadMemoryItem(memoryItemID) else {
            throw KnowledgeStoreError.invalidData("Memory item \(memoryItemID) does not exist.")
        }
        guard item.status != .retired else { return }
        try setMemoryItemStatus(id: memoryItemID, status: .retired, updatedAt: now)
        if try recordsMemoryForGeneration2() { try markCardRecordRetired(memoryItemID, at: now) }
    }

    // MARK: Start over

    /// "Start this card over?": a kept card whose back or why the learner
    /// edits. Nothing in an item changes after Keep, so the old item is
    /// retired, keeping its attempts, and `revision` — the edited card under a
    /// new card id (`MemoryCard.cardID`, minted by the caller) — is kept as a
    /// new item on the same passages, checked again against the source's text,
    /// with the old item's goal and idea (a card kept since cards has no goal;
    /// an item from before cards may, and its revision's card id is new, so no
    /// other device keeps the same item). Both happen in one transaction.
    /// The revision is new, so its schedule starts over too. Throws, and
    /// changes nothing, when the revision reuses a kept card's id or none of
    /// the old passages is still in its source. The caller then records it in
    /// the deck's state (`MemoryCardDeckState.recordStartOver`). Under
    /// generation 2 the revision's item is its card id, as the phone keeps
    /// one, and its Card supersedes the retired one on the same deck, with
    /// its origin, seed and "always ask it this way".
    @discardableResult
    func startMemoryCardOver(
        memoryItemID: String,
        as revision: MemoryCard,
        at now: Date = Date()
    ) throws -> MemoryItem {
        guard let old = try loadMemoryItem(memoryItemID) else {
            throw KnowledgeStoreError.invalidData("Memory item \(memoryItemID) does not exist.")
        }
        guard revision.origin != .legacy else {
            throw KnowledgeStoreError.invalidData(MemoryCardError.legacyCard(revision.cardID).localizedDescription)
        }
        let records = try recordsMemoryForGeneration2()
        let newID = records ? revision.cardID : MemoryTutorIdentity.cardItemID(cardID: revision.cardID)
        guard newID != old.id, revision.cardID != old.id,
              revision.cardID != MemoryCard(storedIn: old)?.cardID,
              try loadMemoryItem(newID) == nil else {
            throw KnowledgeStoreError.invalidData(
                "Card \(revision.cardID) is kept already; a card started over needs a new card id."
            )
        }
        let anchors = old.sources
            .sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.id < $1.id
            }
            .compactMap { try? validatedMemorySourceAnchor(sourceID: $0.sourceID, excerpt: $0.excerpt) }
        guard !anchors.isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "Memory item \(memoryItemID)'s passages are no longer in its source's text, so a card started over has no anchor."
            )
        }
        let item: MemoryItem
        do {
            item = try revision.memoryItem(id: newID, anchors: anchors, goalID: old.goalID, ideaID: old.ideaID, at: now)
        } catch let error as MemoryCardError {
            throw KnowledgeStoreError.invalidData(error.localizedDescription)
        }
        try saveMemoryItem(item, retiring: old.id, at: now)
        if records { try recordCardRecordStartOver(oldID: old.id, old: old, newID: newID, at: now) }
        return item
    }

    // MARK: Self-graded answers

    /// A card the learner graded themselves (`MemoryAttempt.selfGraded`),
    /// written only when it counts. Storage decides that, from the card's own
    /// history, so no caller can write an answer that should not move the
    /// schedule:
    ///
    /// - one answer per card per sitting: the attempt's id is derived from
    ///   `sessionKey` (the caller's id for the sitting) and the card
    ///   (`MemoryTutorIdentity.selfGradedAttemptID`), so a card answered again
    ///   in the same sitting ("Review forgotten") is `.alreadyRecorded`, and a
    ///   second Forgot never halves its stability again;
    /// - a retired card is `.retired`;
    /// - otherwise the card must be due, or new and eligible, or, in
    ///   learner-started `practice`, new (`MemoryCardQueue.answerCounts`);
    ///   anything else is `.notCounted`.
    ///
    /// Throws for an item that does not exist and for an empty `sessionKey`.
    @discardableResult
    func recordSelfGradedMemoryCardAttempt(
        memoryItemID: String,
        prompt: String,
        remembered: Bool,
        sessionKey: String,
        practice: Bool = false,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> MemoryCardAnswerOutcome {
        guard !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("A self-graded answer needs the sitting it was given in.")
        }
        guard let item = try loadMemoryItem(memoryItemID) else {
            throw KnowledgeStoreError.invalidData("Memory item \(memoryItemID) does not exist.")
        }
        let attemptID = MemoryTutorIdentity.selfGradedAttemptID(sessionKey: sessionKey, memoryItemID: memoryItemID)
        if try loadMemoryAttempt(attemptID) != nil { return .alreadyRecorded }
        guard item.status == .active else { return .retired }
        let schedule = MemoryTutorScheduler.schedule(
            item: item,
            attempts: try loadMemoryAttempts(memoryItemID: memoryItemID),
            calendar: calendar
        )
        guard MemoryCardQueue.answerCounts(status: item.status, schedule: schedule, now: now, practice: practice) else {
            return .notCounted
        }
        let inserted = try recordMemoryAttempt(.selfGraded(
            id: attemptID,
            memoryItemID: memoryItemID,
            prompt: prompt,
            remembered: remembered,
            at: now
        ))
        return inserted ? .recorded : .alreadyRecorded
    }

    // MARK: "This asks something else"

    /// "This asks something else" on a card asked in one of its variants
    /// (docs/memory-design.md, "Variations"): a failed attempt — so it moves
    /// no schedule — with the rewording as its prompt and its place in the
    /// card's variants as evidence, which retires that rewording from the
    /// rotation on every device (`MemoryCardVariation.retired`). Once per
    /// sitting and wording: the attempt's id is derived from `sessionKey`,
    /// the card and the wording. Returns whether it was written now; a
    /// retired card writes nothing. Throws for an item that does not exist
    /// and for an empty `sessionKey` or wording.
    @discardableResult
    func recordMemoryCardAskedSomethingElse(
        memoryItemID: String,
        prompt: String,
        variantIndex: Int,
        sessionKey: String,
        at now: Date = Date()
    ) throws -> Bool {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let wording = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !wording.isEmpty else {
            throw KnowledgeStoreError.invalidData("\u{201C}This asks something else\u{201D} needs the sitting and the wording it was said of.")
        }
        guard let item = try loadMemoryItem(memoryItemID) else {
            throw KnowledgeStoreError.invalidData("Memory item \(memoryItemID) does not exist.")
        }
        guard item.status == .active else { return false }
        let id = Self.askedSomethingElseAttemptID(sessionKey: key, memoryItemID: memoryItemID, prompt: wording)
        if try loadMemoryAttempt(id) != nil { return false }
        return try recordMemoryAttempt(MemoryCardVariation.askedSomethingElseAttempt(
            id: id,
            memoryItemID: memoryItemID,
            prompt: wording,
            variantIndex: variantIndex,
            at: now
        ))
    }

    /// One sitting's "This asks something else" on one wording of one card.
    static func askedSomethingElseAttemptID(sessionKey: String, memoryItemID: String, prompt: String) -> String {
        let fields = [sessionKey, memoryItemID, prompt].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
        return "memory-asked-else-v1-" + digest
    }
}
