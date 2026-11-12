import Foundation
import Observation
import OSLog

/// A memory review that has a window to itself
/// (`StudioWindowState.memoryReviewFocus`): a card review, which the Memory
/// pane's Start Review begins, or a day's review chat from before cards.
enum MemoryReviewFocus {
    case chat(String)
    case cards(MemoryCardSessionModel)

    /// The chat's session id, or the card sitting's key.
    var id: String {
        switch self {
        case .chat(let sessionID): return sessionID
        case .cards(let session): return session.id
        }
    }
}

/// One card review on the Mac: a sitting (`MemoryCardSitting`), the answers
/// it writes, and what comes after a round (docs/memory-design.md, "The card
/// review"). `MemoryCardSessionView` shows it in the window-filling memory
/// focus; `StudioViewModel.requestCardReview(scope:)` makes it.
///
/// Answers are written in the order they were given, one at a time, through
/// `StorageService.recordSelfGradedMemoryCardAttempt` with the sitting's key,
/// so storage decides what counts and a card is written once per sitting. A
/// write that fails is said under the card; the review goes on, and the card
/// stays due for another day.
///
/// **Go Deeper** (D, beside Forgot and Remembered) answers the card
/// Remembered and then, in place of the next card, asks one understanding
/// probe past it (`MemoryUnderstandingProbe`, docs/memory-design.md "Go
/// Deeper on a card"): a question, the learner's answer, a short reply, and
/// Next Card, which is there from the start, so the probe is never a gate.
/// The two model calls and the analogy's partner come in as `DeeperSteps`,
/// so the states are tested without a model; nothing they produce is stored.
///
/// **Check** sends the learner's answer to the Card Answer Check task
/// (`AnswerCheckStep`, docs/memory-design.md "The answer is checked") while
/// the back opens: the verdict, kept in the sitting, suggests the grade,
/// which Return confirms (`confirmVerdict`) and Forgot or Remembered
/// overrides. A check that fails is said on the card and the learner grades
/// themselves.
@MainActor
@Observable
final class MemoryCardSessionModel: Identifiable {
    /// What the review reads after a round: more of today's cards in its
    /// scope, and whether today still holds any card in any notebook.
    struct Followup: Sendable {
        let cards: [MemoryCardSitting.Card]
        let dayHasCardsLeft: Bool
    }

    /// What Go Deeper needs from outside the review: the analogy's partner
    /// for a card's source (off the main actor; nil when there is none, which
    /// leaves the analogy out of the rotation), the question for a card (nil
    /// when no kind fits it), and the reply to the learner's answer. Thrown
    /// errors are said under the panel.
    struct DeeperSteps {
        let partner: @MainActor (_ sourceID: String) async -> MemoryUnderstandingProbe.AnalogyPartner?
        let question: @MainActor (_ request: MemoryUnderstandingProbe.CardQuestionRequest, _ cardID: String) async throws
            -> MemoryUnderstandingProbe.CardQuestion?
        let reply: @MainActor (_ request: MemoryUnderstandingProbe.CardReplyRequest, _ cardID: String) async throws -> String
    }

    /// The model's check of an answer (`AIService.checkCardAnswer`), for the
    /// card the request is about. Thrown errors are said on the card.
    typealias AnswerCheckStep = @MainActor (_ request: MemoryCardAnswerCheck.Request, _ cardID: String, _ sourceTitle: String?) async throws
        -> MemoryCardAnswerCheck.Result

    /// The panel Go Deeper opens for the card it answered.
    struct Deeper: Equatable, Identifiable {
        enum Stage: Equatable {
            /// The question is being written.
            case writingQuestion
            /// No question: no kind fits the card (`failure` nil), or the
            /// question could not be written (`failure` says why).
            case noQuestion
            /// The question, waiting for the learner's answer.
            case asking(MemoryUnderstandingProbe.CardQuestion)
            /// The answer sent, the reply being written.
            case replying(MemoryUnderstandingProbe.CardQuestion, answer: String)
            case replied(MemoryUnderstandingProbe.CardQuestion, answer: String, reply: String)
        }

        let id: UUID
        let card: MemoryCardSitting.Card
        let sourceTitle: String?
        var stage: Stage
        /// The nearby idea the analogy was offered; nil when there was none.
        var partner: MemoryUnderstandingProbe.AnalogyPartner? = nil
        /// Why the question or the reply could not be written, said in one
        /// line under the panel; nil otherwise.
        var failure: String? = nil

        var question: MemoryUnderstandingProbe.CardQuestion? {
            switch stage {
            case .asking(let question), .replying(let question, _), .replied(let question, _, _): return question
            case .writingQuestion, .noQuestion: return nil
            }
        }

        /// Whether the answer field is on screen: the question is asked and
        /// no answer is on its way. Next Card's keys wait for it to go, so
        /// Return and → stay the field's while the learner types.
        var takesAnswer: Bool {
            if case .asking = stage { return true }
            return false
        }
    }

    /// The sitting's key (`MemoryCardSitting.key`).
    let id: String
    let scope: MemoryReviewScope
    /// What the review is over: "All notebooks", or the notebook's name.
    let scopeTitle: String
    /// Whether taking the window made today's commitment: today's review on
    /// a day still open. Practice, and a day already done, make none.
    let isCommitted: Bool
    /// The cards' sources by id, for each card's eyebrow and chip.
    let sourceTitles: [String: String]
    private(set) var sitting: MemoryCardSitting
    /// Why the last answer was not saved; nil once one is.
    private(set) var saveError: String?
    /// After a round, today's cards in the scope that this sitting has not
    /// dealt yet (Continue).
    private(set) var waitingCards: [MemoryCardSitting.Card] = []
    /// Reading what comes after a round.
    private(set) var isReadingFollowup = false
    /// A draft the learner edited is being kept: its card waits for the
    /// write before it can be answered.
    private(set) var isKeepingDraft = false
    /// The source the Reader beside the review shows, opened from a card's
    /// chip. Nil while the review has the window to itself.
    var besideSourceID: String?
    /// Go Deeper's panel, in place of the next card; nil otherwise.
    private(set) var deeper: Deeper?
    /// The learner's answer to the panel's question, as it is typed.
    var deeperDraft = ""
    /// The learner's answer to the card on screen, as it is typed or
    /// dictated, before Check turns the card.
    var attemptDraft = ""

    @ObservationIgnored private let storage: StorageService
    /// Where the drafts' `cards.state.<deckID>` rows are read and written: the
    /// standard defaults, or a test's own suite.
    @ObservationIgnored private let stateDefaults: UserDefaults
    @ObservationIgnored private let followup: @MainActor () async throws -> Followup
    /// Told once, when today's review has answered its first deal through,
    /// whether any notebook still has a card today: the day then releases
    /// the commitment, or is done (`StudioViewModel.cardReviewAnsweredFirstDeal`).
    @ObservationIgnored private let firstDealAnswered: @MainActor (_ dayHasCardsLeft: Bool) -> Void
    @ObservationIgnored private var hasReportedFirstDeal = false
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private let deeperSteps: DeeperSteps?
    @ObservationIgnored private let answerCheckStep: AnswerCheckStep?
    /// The check of the answer on screen, while it runs.
    @ObservationIgnored private var checkWork: Task<Void, Never>?
    /// The model work of the panel showing: its question, then its reply.
    @ObservationIgnored private var deeperWork: Task<Void, Never>?
    /// The kind of the last probe asked in this sitting: the kinds rotate.
    @ObservationIgnored private var lastDeeperKind: MemoryUnderstandingProbe.Kind?
    @ObservationIgnored private let logger = Logger(subsystem: "com.foreverlm", category: "MemoryCardReview")

    init(
        sitting: MemoryCardSitting,
        scope: MemoryReviewScope,
        scopeTitle: String,
        isCommitted: Bool,
        sourceTitles: [String: String],
        storage: StorageService,
        stateDefaults: UserDefaults = .standard,
        followup: @escaping @MainActor () async throws -> Followup,
        firstDealAnswered: @escaping @MainActor (_ dayHasCardsLeft: Bool) -> Void = { _ in },
        deeper: DeeperSteps? = nil,
        answerCheck: AnswerCheckStep? = nil
    ) {
        self.id = sitting.key
        self.sitting = sitting
        self.scope = scope
        self.scopeTitle = scopeTitle
        self.isCommitted = isCommitted
        self.sourceTitles = sourceTitles
        self.storage = storage
        self.stateDefaults = stateDefaults
        self.followup = followup
        self.firstDealAnswered = firstDealAnswered
        self.deeperSteps = deeper
        self.answerCheckStep = answerCheck
    }

    /// Whether leaving now ends today's session: the review made the
    /// commitment and its first deal is not answered through. A sitting
    /// whose cards were all answered was not left early.
    var leavingEndsSession: Bool {
        isCommitted && !sitting.firstDealAnswered
    }

    /// The source of the card on screen, by name: Go Deeper's card while
    /// its panel shows.
    var currentSourceTitle: String? {
        if let deeper { return deeper.sourceTitle }
        return sitting.current?.sourceID.flatMap { sourceTitles[$0] }
    }

    /// Whether the review offers Go Deeper: a review made with its steps.
    var offersGoDeeper: Bool { deeperSteps != nil }

    /// Check: the learner's answer turns the card to its back, the answer
    /// shown over it, and goes to the model to be checked. A blank answer
    /// turns nothing. True when the back shows.
    @discardableResult
    func showAnswer(attempt: String) -> Bool {
        guard sitting.showAnswer(attempt: attempt) else { return false }
        attemptDraft = ""
        startAnswerCheck()
        return true
    }

    /// Whether the review checks answers with a model: one made with the
    /// step. A review made without it (a test's) grades by the learner alone.
    var checksAnswers: Bool { answerCheckStep != nil }

    /// Sends the answer on screen to the check, off the main actor; the
    /// verdict lands in the sitting only while its card still waits for it.
    private func startAnswerCheck() {
        guard let step = answerCheckStep, let begun = sitting.beginAnswerCheck() else { return }
        let sourceTitle = sitting.current?.sourceID.flatMap { sourceTitles[$0] }
        checkWork?.cancel()
        checkWork = Task { [weak self] in
            let outcome: MemoryCardSitting.AnswerCheck
            do {
                let result = try await step(begun.request, begun.itemID, sourceTitle)
                outcome = .judged(result)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                self?.logger.error("A card answer was not checked: \(error.localizedDescription, privacy: .public)")
                outcome = .failed(MemoryCardAnswerCheck.failureLine(error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            self?.sitting.settleAnswerCheck(outcome, token: begun.token)
        }
    }

    /// Return once the verdict is in: the grade it suggests. Nothing while
    /// the check runs, or when it failed.
    func confirmVerdict() {
        guard let remembered = sitting.verdictRemembers else { return }
        answer(remembered: remembered)
    }

    /// The check of the answer on screen, for a test to wait on.
    func waitForAnswerCheck() async {
        await checkWork?.value
    }

    /// Check on what the learner has typed or dictated.
    @discardableResult
    func checkAttempt() -> Bool {
        showAnswer(attempt: attemptDraft)
    }

    /// Show Answer: the back shows with nothing typed, and the learner
    /// grades themselves.
    func showAnswerUnanswered() {
        sitting.showAnswerUnanswered()
        if sitting.isAnswerShown { attemptDraft = "" }
    }

    /// Forgot or Remembered on the card on screen, once its back is shown.
    /// On a draft a notebook's Practice dealt, the answer keeps it first.
    func answer(remembered: Bool) {
        guard sitting.isAnswerShown, !isKeepingDraft else { return }
        // Graded before the verdict came: the learner's own grade stands, and
        // the check is no longer waited for.
        checkWork?.cancel()
        checkWork = nil
        if let answer = sitting.answer(remembered: remembered) {
            record(answer)
        }
        if sitting.isRoundOver { readFollowup() }
    }

    /// Skip (S) on a draft: dropped for good, as in To Check
    /// (`MemoryCardTriageWriter`), and the round moves on with nothing
    /// answered.
    func skipCurrentDraft() {
        guard !isKeepingDraft, let draft = sitting.skipCurrentDraft() else { return }
        attemptDraft = ""
        let previous = writes
        let storage = storage
        let defaults = stateDefaults
        writes = Task { [weak self] in
            await previous?.value
            let result = await MemoryCardTriageWriter.apply(
                [MemoryCardTriageDecision(card: draft, action: .skip)],
                storage: storage,
                defaults: defaults
            )
            if let failure = result.failed.first {
                self?.saveError = "That card was not skipped. \(failure.reason)"
            }
        }
        if sitting.isRoundOver { readFollowup() }
    }

    /// Delete on a kept card, before or after its back shows: it leaves the
    /// round at once, unanswered. Nothing is written here: the caller retires
    /// it once Undo's window closes (`StudioViewModel.deleteCardFromReview`),
    /// and Undo before then puts it back (`restore`). Nil for a draft (Skip
    /// drops one), while a draft is being kept, and under Go Deeper's panel.
    @discardableResult
    func deleteCurrent() -> MemoryCardSitting.Removed? {
        guard !isKeepingDraft, deeper == nil, let removed = sitting.removeCurrent() else { return nil }
        checkWork?.cancel()
        checkWork = nil
        attemptDraft = ""
        waitingCards.removeAll { $0.itemID == removed.card.itemID }
        if sitting.isRoundOver { readFollowup() }
        return removed
    }

    /// Undo of a delete: the card back in front of the learner, its question
    /// to answer. False when its round is over and another dealt.
    @discardableResult
    func restore(_ removed: MemoryCardSitting.Removed) -> Bool {
        guard deeper == nil, sitting.restore(removed) else { return false }
        checkWork?.cancel()
        checkWork = nil
        attemptDraft = ""
        return true
    }

    /// Edit (E), then Keep, on a draft before it is answered: the card is
    /// kept in the learner's words (`MemoryCardTriageWriter`, as To Check's
    /// Edit), and it stays on screen as the kept card, its answer still to
    /// give. From the call until the write lands the card cannot be answered
    /// or skipped. The work answers whether it was kept; a refusal is said
    /// under the card, which stays a draft. Nil when the card on screen is
    /// no draft.
    @discardableResult
    func keepCurrentDraft(edited edit: MemoryCardEdit) -> Task<Bool, Never>? {
        guard !isKeepingDraft, let card = sitting.current, let draft = card.draft else { return nil }
        isKeepingDraft = true
        let previous = writes
        let storage = storage
        let defaults = stateDefaults
        let keeping = Task { [weak self] () -> Bool in
            await previous?.value
            let result = await MemoryCardTriageWriter.apply(
                [MemoryCardTriageDecision(card: draft, action: .keepEdited(edit))],
                storage: storage,
                defaults: defaults
            )
            guard let self else { return false }
            defer { self.isKeepingDraft = false }
            guard let kept = result.kept.first, let face = MemoryCardTriage.editedFace(draft, edit) else {
                self.saveError = "That card was not kept. \(result.failed.first?.reason ?? "")"
                return false
            }
            self.sitting.keepDraft(itemID: card.itemID, as: card.keptEdited(face, as: kept.memoryItemID, alsoFrom: edit.alsoFrom))
            self.saveError = nil
            return true
        }
        writes = Task { _ = await keeping.value }
        return keeping
    }

    /// The round's forgotten cards again. Nothing they answer is written.
    func reviewForgotten() {
        sitting.reviewForgotten()
    }

    /// "This asks something else" on the card on screen, asked in one of
    /// its rewordings (docs/memory-design.md, "Variations"): a failed attempt
    /// that moves no schedule and retires that rewording on every device
    /// (`recordMemoryCardAskedSomethingElse`), and the card asked in its own
    /// words, for the learner to answer as usual.
    func reportAskedSomethingElse() {
        guard let card = sitting.current, card.isVariant, let index = card.variantIndex else { return }
        sitting.askCurrentInOwnWords()
        let previous = writes
        let storage = storage
        let key = id
        writes = Task { [weak self] in
            await previous?.value
            do {
                _ = try await storage.recordMemoryCardAskedSomethingElse(
                    memoryItemID: card.itemID,
                    prompt: card.prompt,
                    variantIndex: index,
                    sessionKey: key
                )
            } catch {
                self?.logger.error("A retired rewording was not saved: \(error.localizedDescription, privacy: .public)")
                self?.saveError = "That rewording was not taken out. \(error.localizedDescription)"
            }
        }
    }

    /// "Always ask it this way" on the card on screen, or off again: written
    /// in its deck's row (`MemoryCardStateStore.setAlwaysAsk`), and a card
    /// asked in a rewording is asked in its own words at once.
    func setAlwaysAsk(_ on: Bool) {
        guard let card = sitting.current, let deckID = card.deckID else { return }
        MemoryCardStateStore.setAlwaysAsk(
            on,
            cardID: card.cardID,
            memoryItemID: card.itemID,
            deckID: deckID
        )
        sitting.setCurrentAlwaysAsk(on)
    }

    /// More of today's cards, once a round is over.
    func continueWithWaitingCards() {
        guard sitting.dealMore(waitingCards) else { return }
        waitingCards = []
    }

    /// The writes still on their way, for the caller that must see them
    /// land (a test, or the end of the review).
    func waitForWrites() async {
        await writes?.value
    }

    /// What follows the last round, once it has been read (a test's wait).
    func waitForFollowup() async {
        await followupRead?.value
    }

    // MARK: Go Deeper

    /// Go Deeper (D) on the card on screen, once its back is shown: the card
    /// is answered Remembered, exactly as Remembered answers it (a draft is
    /// kept the same way), and the panel opens in place of the next card
    /// while its question is written: the analogy's partner is looked up
    /// first, and the kinds go to the writer in rotation order after the
    /// last one asked in this sitting.
    func goDeeper() {
        guard let steps = deeperSteps, sitting.isAnswerShown, !isKeepingDraft, let card = sitting.current else { return }
        answer(remembered: true)
        deeperWork?.cancel()
        let panel = Deeper(
            id: UUID(),
            card: card,
            sourceTitle: card.sourceID.flatMap { sourceTitles[$0] },
            stage: .writingQuestion
        )
        deeper = panel
        deeperDraft = ""
        let last = lastDeeperKind
        deeperWork = Task { [weak self] in
            let partner: MemoryUnderstandingProbe.AnalogyPartner?
            if let sourceID = card.sourceID {
                partner = await steps.partner(sourceID)
            } else {
                partner = nil
            }
            guard let self, self.deeper?.id == panel.id, !Task.isCancelled else { return }
            self.deeper?.partner = partner
            let request = MemoryUnderstandingProbe.CardQuestionRequest(
                front: card.prompt,
                back: card.back,
                why: card.why,
                sourceTitle: panel.sourceTitle,
                kinds: MemoryUnderstandingProbe.rotation(after: last, includesAnalogy: partner != nil),
                partner: partner
            )
            do {
                let question = try await steps.question(request, card.itemID)
                guard self.deeper?.id == panel.id, !Task.isCancelled else { return }
                if let question {
                    self.lastDeeperKind = question.kind
                    self.deeper?.stage = .asking(question)
                } else {
                    self.deeper?.stage = .noQuestion
                }
            } catch {
                guard self.deeper?.id == panel.id, !Task.isCancelled, !(error is CancellationError) else { return }
                self.logger.error("Go Deeper's question was not written: \(error.localizedDescription, privacy: .public)")
                self.deeper?.stage = .noQuestion
                self.deeper?.failure = "The question could not be written. \(error.localizedDescription)"
            }
        }
    }

    /// Return in the panel's field: the answer goes to the reply writer. A
    /// reply that fails is said under the panel, and the answer goes back
    /// into the field to send again.
    func sendDeeperAnswer() {
        guard let steps = deeperSteps, let panel = deeper, case .asking(let question) = panel.stage else { return }
        let answer = deeperDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        deeperDraft = ""
        deeper?.stage = .replying(question, answer: answer)
        deeper?.failure = nil
        let request = MemoryUnderstandingProbe.CardReplyRequest(
            front: panel.card.prompt,
            back: panel.card.back,
            why: panel.card.why,
            sourceTitle: panel.sourceTitle,
            question: question,
            answer: answer,
            partner: panel.partner
        )
        deeperWork = Task { [weak self] in
            do {
                let reply = try await steps.reply(request, panel.card.itemID)
                guard let self, self.deeper?.id == panel.id, !Task.isCancelled else { return }
                self.deeper?.stage = .replied(question, answer: answer, reply: reply)
            } catch {
                guard let self, self.deeper?.id == panel.id, !Task.isCancelled, !(error is CancellationError) else { return }
                self.logger.error("Go Deeper's reply was not written: \(error.localizedDescription, privacy: .public)")
                self.deeper?.stage = .asking(question)
                self.deeper?.failure = "The reply could not be written. \(error.localizedDescription)"
                if self.deeperDraft.isEmpty { self.deeperDraft = answer }
            }
        }
    }

    /// Next Card: the panel goes, whatever it is waiting for, and the next
    /// card (or the end of the round) is on screen.
    func leaveDeeper() {
        deeperWork?.cancel()
        deeperWork = nil
        deeper = nil
        deeperDraft = ""
    }

    /// The panel's model work, for a test to wait on.
    func waitForDeeper() async {
        await deeperWork?.value
    }

    // MARK: Writing

    /// One answer, after those before it. A draft's answer keeps the draft
    /// first, as To Check's Keep does (`MemoryCardTriageWriter`), and is then
    /// written as the kept card's first answer, practice the learner started
    /// counting a card kept today; a draft storage refuses to keep is said
    /// under the card and nothing is answered for it.
    private func record(_ answer: MemoryCardSitting.Answer) {
        let previous = writes
        let storage = storage
        let defaults = stateDefaults
        let key = id
        writes = Task { [weak self] in
            await previous?.value
            var itemID = answer.itemID
            if let draft = answer.keeping {
                let kept = await MemoryCardTriageWriter.apply(
                    [MemoryCardTriageDecision(card: draft, action: .keep)],
                    storage: storage,
                    defaults: defaults
                )
                guard let item = kept.kept.first else {
                    let reason = kept.failed.first?.reason ?? ""
                    self?.logger.error("A card to check was not kept: \(reason, privacy: .public)")
                    self?.saveError = "That card was not kept, so your answer was not saved. \(reason)"
                    return
                }
                itemID = item.memoryItemID
            }
            do {
                _ = try await storage.recordSelfGradedMemoryCardAttempt(
                    memoryItemID: itemID,
                    prompt: answer.prompt,
                    remembered: answer.remembered,
                    sessionKey: key,
                    practice: answer.practice
                )
                self?.saveError = nil
            } catch {
                self?.logger.error("A card answer was not saved: \(error.localizedDescription, privacy: .public)")
                self?.saveError = "Your answer to the last card was not saved. \(error.localizedDescription)"
            }
        }
    }

    // MARK: After a round

    @ObservationIgnored private var followupRead: Task<Void, Never>?

    /// Once the answers have landed: what more today holds in the scope, and
    /// whether the day's cards ran out. Today's review that has answered its
    /// first deal through says so once (`firstDealAnswered`): nothing it
    /// promised is left, and when no notebook has a card left today the day
    /// is done (decisions 2026-09-30, call 1).
    private func readFollowup() {
        isReadingFollowup = true
        let previous = writes
        followupRead = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.isReadingFollowup = false }
            do {
                let next = try await self.followup()
                self.waitingCards = next.cards.filter {
                    !self.sitting.recordedItemIDs.contains($0.itemID) && !self.sitting.removedItemIDs.contains($0.itemID)
                }
                guard self.sitting.kind == .today, self.sitting.firstDealAnswered, !self.hasReportedFirstDeal else { return }
                self.hasReportedFirstDeal = true
                self.firstDealAnswered(next.dayHasCardsLeft)
            } catch {
                self.logger.error("What follows the round could not be read: \(error.localizedDescription, privacy: .public)")
                self.waitingCards = []
            }
        }
    }
}
