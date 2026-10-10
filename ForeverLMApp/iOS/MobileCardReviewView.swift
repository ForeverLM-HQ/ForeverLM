import OSLog
import PDFKit
import SwiftUI
import UIKit

// The card review on the iPhone (docs/memory-design.md, "The card review on
// the iPhone"). The product owner, 2026-10-01: keep the ability to "make flashcards and
// recall based off of all notebooks that I have worked on"; 2026-09-30:
// Recall's review is "always in focus and clean". Today's cards, one at a
// time, across every notebook or narrowed to one, as the Mac's card review
// deals them; and a notebook's Practice from its Studio. The sitting is the
// Mac's (`MemoryCardSitting`), the deal the Mac's (`MemoryCardDeal`), the
// wording the Mac's (`MemoryCardWording`), and each answer is written as the
// Mac's store writes a self-graded answer (`MobileSelfGradedAnswer`, through
// `MobileMemoryAttemptRecorder.recordSelfGraded`).

// MARK: - The sitting on the phone

/// One card review on the phone: what it deals, where the learner is in it,
/// and the answers it writes. Answers are written one at a time, in the order
/// they were given, each as soon as it is given, under the sitting's key, so
/// a card is written once per sitting whatever the screen does; each write
/// holds the app awake until it lands, so an answer given just before the
/// phone locks or the app goes to the background still reaches iCloud. A
/// write that fails is said under the card, and the review goes on. Opening
/// reads and writes nothing.
@MainActor
final class MobileCardReviewSession: ObservableObject {
    enum Mode: Hashable, Sendable {
        /// Today's cards over every notebook or one, or the scope's new
        /// cards as practice: when today holds none there and the learner
        /// asks, or when the sitting is opened as practice.
        case today(MemoryReviewScope)
        /// A notebook's Practice: its kept cards, due, then new, then not
        /// yet due.
        case notebookPractice(notebookID: String)
    }

    enum Phase: Equatable {
        case loading
        /// Nothing to deal: today holds no card in the scope, or the notebook
        /// has no kept card.
        case empty
        case reviewing
    }

    /// One read of the cards for a sitting.
    struct Deal {
        var cards: [MemoryCardSitting.Card]
        /// The scope's new cards outside today's deal, which the empty review
        /// offers to practice; 0 in a notebook's Practice.
        var practiceCount: Int
        /// The cards' sources by id, for each card's eyebrow and chip.
        var sourceTitles: [String: String]

        static let none = Deal(cards: [], practiceCount: 0, sourceTitles: [:])
    }

    /// Everything the sitting reads and writes, so a test names its own.
    struct Backend {
        /// The cards to deal: today's in a scope or its new cards as practice
        /// (`kind`), or a notebook's Practice.
        var deal: @MainActor (_ mode: Mode, _ kind: MemoryCardSitting.Kind, _ now: Date) async -> Deal
        /// The notebooks a review may be narrowed to.
        var notebookIDs: @MainActor () async -> Set<String>
        /// A card's item, whatever its status, and its whole history.
        var answerContext: @MainActor (_ itemID: String) async -> (item: MemoryItem, history: [MemoryAttempt])?
        /// Writes one decided answer.
        var write: @MainActor (_ attempt: MemoryAttempt, _ parentCurriculumFingerprint: String) async throws -> MemoryCardAnswerOutcome
        /// A saved answer, published in the catalog.
        var noteRecorded: @MainActor (_ attempt: MemoryAttempt) async -> Void
        /// Whether today's review chat from before cards holds an answer.
        var dayChatIsUnderway: @MainActor () async -> Bool
        /// Holds the app awake while a write runs; the closure it returns
        /// lets go.
        var keepAwake: @MainActor () -> () -> Void
        var now: @MainActor () -> Date = { Date() }
        /// "This asks something else" on a card asked in a rewording: the
        /// rewording taken out, and the failed attempt that says so.
        var askedSomethingElse: @MainActor (_ itemID: String, _ prompt: String, _ variantIndex: Int, _ sessionKey: String, _ at: Date) async throws -> Void = { _, _, _, _, _ in }
        /// "Always ask it this way" on a card, or off again.
        var setAlwaysAsk: @MainActor (_ itemID: String, _ on: Bool) async throws -> Void = { _, _ in }
    }

    @Published private(set) var mode: Mode
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var sitting: MemoryCardSitting?
    @Published private(set) var sourceTitles: [String: String] = [:]
    @Published private(set) var practiceCount = 0
    /// Why the last answer was not saved; nil once one is.
    @Published private(set) var saveError: String?
    /// After a round of today's review: today's cards in the scope this
    /// sitting has not dealt yet (Continue).
    @Published private(set) var waitingCards: [MemoryCardSitting.Card] = []
    @Published private(set) var isReadingFollowup = false
    /// Whether today's review chat from before cards can be continued.
    @Published private(set) var dayChatIsUnderway = false
    /// Counts the answers shown and given, for the haptics.
    @Published private(set) var revealCount = 0
    @Published private(set) var answerCount = 0

    private let backend: Backend
    /// Whether opening deals the scope's new cards outside today's deal as
    /// practice, rather than today's cards: the Memory screen's Practice N
    /// New Cards. A change of scope deals the new scope's the same way.
    private let opensAsPractice: Bool
    private var hasOpened = false
    /// Which read of the cards is the current one: a scope changed while a
    /// read was out discards that read.
    private var dealGeneration = 0
    private var writes: Task<Void, Never>?
    private var followupRead: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "CardReview")

    init(mode: Mode, opensAsPractice: Bool = false, backend: Backend) {
        self.mode = mode
        self.opensAsPractice = opensAsPractice
        self.backend = backend
    }

    convenience init(mode: Mode, opensAsPractice: Bool = false) {
        self.init(mode: mode, opensAsPractice: opensAsPractice, backend: .live())
    }

    /// The notebook a card's Reader opens in: the notebook the review is
    /// narrowed to, or nil over every notebook.
    var notebookInScope: String? {
        switch mode {
        case .today(.allNotebooks): return nil
        case .today(.notebook(let notebookID)), .notebookPractice(let notebookID): return notebookID
        }
    }

    /// The source of the card on screen, by name.
    var currentSourceTitle: String? {
        sitting?.current?.sourceID.flatMap { sourceTitles[$0] }
    }

    // MARK: Opening

    /// Deals the cards, once: coming back from a card's Reader keeps the
    /// sitting where it was. Reads only.
    func open() async {
        guard !hasOpened else { return }
        hasOpened = true
        if case .today(let scope) = mode {
            let valid = MobileCardReviewCopy.validScope(scope, notebookIDs: await backend.notebookIDs())
            if valid != scope { mode = .today(valid) }
        }
        async let chat = backend.dayChatIsUnderway()
        await deal(kind: openingKind)
        dayChatIsUnderway = await chat
    }

    /// Practice when the sitting was opened as practice; otherwise the
    /// mode's own (today's cards, or a notebook's Practice).
    private var openingKind: MemoryCardSitting.Kind? {
        opensAsPractice ? .practice : nil
    }

    /// The scope control: every notebook or one. A new sitting, as the Mac's
    /// Start Review after a change of scope is.
    func changeScope(_ scope: MemoryReviewScope) {
        guard case .today(let current) = mode, current != scope else { return }
        mode = .today(scope)
        Task { await deal(kind: openingKind) }
    }

    /// The empty review's Practice N New Cards: the scope's new cards that
    /// today's deal leaves out — kept today, or past the day's allowance —
    /// as practice the learner started, whose first answers count.
    func startPractice() {
        guard case .today = mode, phase == .empty, practiceCount > 0 else { return }
        Task { await deal(kind: .practice) }
    }

    private func deal(kind requested: MemoryCardSitting.Kind?) async {
        dealGeneration += 1
        let generation = dealGeneration
        phase = .loading
        sitting = nil
        waitingCards = []
        isReadingFollowup = false
        let kind: MemoryCardSitting.Kind
        switch mode {
        case .today: kind = requested ?? .today
        case .notebookPractice: kind = .practice
        }
        let now = backend.now()
        let deal = await backend.deal(mode, kind, now)
        guard generation == dealGeneration else { return }
        practiceCount = deal.practiceCount
        sourceTitles = deal.sourceTitles
        guard !deal.cards.isEmpty else {
            phase = .empty
            return
        }
        sitting = MemoryCardSitting(
            key: MemoryCardSitting.newKey(day: MemoryReviewGoal.dayKey(for: now)),
            kind: kind,
            cards: deal.cards
        )
        phase = .reviewing
    }

    // MARK: The cards

    func showAnswer() {
        guard var sitting, !sitting.isAnswerShown, sitting.current != nil else { return }
        sitting.showAnswer()
        self.sitting = sitting
        revealCount += 1
    }

    /// Forgot or Remembered on the card on screen, once its back is shown.
    /// The first answer to a card in the sitting is written (when the Mac's
    /// rules say it counts); a repeat is shown and writes nothing.
    func answer(remembered: Bool) {
        guard var sitting, sitting.isAnswerShown else { return }
        let answeredAt = backend.now()
        let answer = sitting.answer(remembered: remembered)
        self.sitting = sitting
        answerCount += 1
        if let answer {
            record(answer, sessionKey: sitting.key, at: answeredAt)
        }
        if sitting.isRoundOver { readFollowup() }
    }

    // MARK: How a card is worded

    /// "This asks something else" on the card on screen, asked in one of its
    /// rewordings (docs/memory-design.md, "Variations"): the card is asked in
    /// its own words at once, its answer hidden, and the rewording is taken
    /// out on every device. The write waits for the answers before it.
    func reportAskedSomethingElse() {
        guard var sitting, let card = sitting.current, card.isVariant, let index = card.variantIndex else { return }
        sitting.askCurrentInOwnWords()
        self.sitting = sitting
        let key = sitting.key
        let at = backend.now()
        enqueue("That rewording was not taken out.") { backend in
            try await backend.askedSomethingElse(card.itemID, card.prompt, index, key, at)
        }
    }

    /// "Always Ask in Its Own Words" on the card on screen, or "Let Its
    /// Wording Vary": on, a card asked in a rewording is asked in its own
    /// words at once.
    func setAlwaysAsk(_ on: Bool) {
        guard var sitting, let card = sitting.current else { return }
        sitting.setCurrentAlwaysAsk(on)
        self.sitting = sitting
        enqueue("The card's wording was not saved.") { backend in
            try await backend.setAlwaysAsk(card.itemID, on)
        }
    }

    /// A write after those before it, holding the app awake until it lands;
    /// a failure is said under the card, after `failure`.
    private func enqueue(_ failure: String, _ body: @escaping @MainActor (Backend) async throws -> Void) {
        let previous = writes
        let backend = backend
        let letGo = backend.keepAwake()
        writes = Task { [weak self] in
            await previous?.value
            defer { letGo() }
            do {
                try await body(backend)
                self?.saveError = nil
            } catch {
                Self.logger.error("A card change was not saved: \(error.localizedDescription, privacy: .public)")
                self?.saveError = "\(failure) \(error.localizedDescription)"
            }
        }
    }

    /// The round's forgotten cards again. Nothing they answer is written.
    func reviewForgotten() {
        guard var sitting, sitting.reviewForgotten() else { return }
        self.sitting = sitting
        waitingCards = []
    }

    /// More of today's cards, once a round is over.
    func continueWithWaitingCards() {
        guard var sitting, sitting.dealMore(waitingCards) else { return }
        self.sitting = sitting
        waitingCards = []
    }

    /// The writes still on their way, for a caller that must see them land.
    func waitForWrites() async {
        await writes?.value
    }

    /// What follows the last round, once it has been read (a test's wait).
    func waitForFollowup() async {
        await followupRead?.value
    }

    // MARK: Writing

    /// One answer, after those before it: decided from the card's history
    /// as this phone holds it (`MobileSelfGradedAnswer`), at the moment it
    /// was given, and written only when it counts.
    private func record(_ answer: MemoryCardSitting.Answer, sessionKey: String, at answeredAt: Date) {
        let previous = writes
        let backend = backend
        let letGo = backend.keepAwake()
        writes = Task { [weak self] in
            await previous?.value
            defer { letGo() }
            do {
                guard let context = await backend.answerContext(answer.itemID) else {
                    throw MobileCardReviewError.cardGone
                }
                let decision = try MobileSelfGradedAnswer.decide(
                    item: context.item,
                    history: context.history,
                    prompt: answer.prompt,
                    remembered: answer.remembered,
                    sessionKey: sessionKey,
                    practice: answer.practice,
                    at: answeredAt
                )
                switch decision {
                case .write(let attempt):
                    _ = try await backend.write(attempt, MemoryTutorIdentity.immutableCurriculumFingerprint(context.item))
                    await backend.noteRecorded(attempt)
                case .skip(let outcome):
                    Self.logger.info("A card answer was not written: \(outcome.rawValue, privacy: .public)")
                }
                self?.saveError = nil
            } catch {
                Self.logger.error("A card answer was not saved: \(error.localizedDescription, privacy: .public)")
                self?.saveError = "Your answer to the last card was not saved. \(error.localizedDescription)"
            }
        }
    }

    // MARK: After a round

    /// Once the answers have landed: the cards today still holds in the
    /// scope that this sitting has not dealt (Continue). Practice deals
    /// nothing after it: today's cards are today's review's.
    private func readFollowup() {
        guard let sitting, sitting.kind == .today else { return }
        isReadingFollowup = true
        let previous = writes
        let backend = backend
        let mode = mode
        let key = sitting.key
        followupRead = Task { [weak self] in
            await previous?.value
            let next = await backend.deal(mode, .today, backend.now())
            guard let self, let current = self.sitting, current.key == key else { return }
            self.waitingCards = next.cards.filter { !current.recordedItemIDs.contains($0.itemID) }
            for (id, title) in next.sourceTitles where self.sourceTitles[id] == nil {
                self.sourceTitles[id] = title
            }
            self.isReadingFollowup = false
        }
    }
}

extension MobileCardReviewSession.Backend {
    /// The phone's own: the synced catalog, the account's card state rows,
    /// CloudKit.
    @MainActor
    static func live() -> Self {
        let vm = MobileAudioReviewViewModel.shared
        return Self(
            deal: { mode, kind, now in
                switch mode {
                case .today(let scope):
                    let read = await vm.cardReviewRead(scope: scope, now: now)
                    let entries = kind == .practice ? read.practice : read.today.entries
                    let cards = await sittingCards(entries, attemptsByItemID: read.attemptsByItemID)
                    return MobileCardReviewSession.Deal(
                        cards: cards,
                        practiceCount: read.practice.count,
                        sourceTitles: titles(of: cards, in: vm)
                    )
                case .notebookPractice(let notebookID):
                    guard let practice = await vm.notebookPractice(notebookID: notebookID, now: now) else { return .none }
                    let cards = await sittingCards(practice.entries, attemptsByItemID: practice.attemptsByItemID)
                    return MobileCardReviewSession.Deal(cards: cards, practiceCount: 0, sourceTitles: titles(of: cards, in: vm))
                }
            },
            notebookIDs: { await vm.cardReviewNotebookIDs() },
            answerContext: { await vm.cardAnswerContext(memoryItemID: $0) },
            write: { attempt, fingerprint in
                try await MobileMemoryAttemptRecorder.shared.recordSelfGraded(attempt, parentCurriculumFingerprint: fingerprint)
            },
            noteRecorded: { await vm.noteRecordedCardAnswer($0) },
            dayChatIsUnderway: { await vm.dayReviewChatIsUnderway() },
            keepAwake: {
                let assertion = MobileBackgroundSaveAssertion(name: "memory-card-answer")
                return { assertion.end() }
            },
            askedSomethingElse: { itemID, prompt, index, key, at in
                try await vm.reportCardAskedSomethingElse(itemID: itemID, prompt: prompt, variantIndex: index, sessionKey: key, at: at)
            },
            setAlwaysAsk: { itemID, on in
                try await vm.setCardAlwaysAsk(on, itemID: itemID)
            }
        )
    }

    /// The entries as cards, worded by their Cards (their rewording, the
    /// rewordings in rotation, "always ask it this way"). A card whose Card
    /// the phone cannot read is asked in its own words: the review still
    /// runs, and what was asked is what is recorded.
    private static func sittingCards(
        _ entries: [MemoryCardQueue.Entry],
        attemptsByItemID: [String: [MemoryAttempt]]
    ) async -> [MemoryCardSitting.Card] {
        let records = await MobileAudioReviewViewModel.shared.cardRecords(itemIDs: entries.map(\.id))
        let states = MobileCardRecords.deckStates(entries, attemptsByItemID: attemptsByItemID, records: records)
        return MobileCardReviewDealing.sittingCards(entries, attemptsByItemID: attemptsByItemID, states: states)
    }

    @MainActor
    private static func titles(of cards: [MemoryCardSitting.Card], in vm: MobileAudioReviewViewModel) -> [String: String] {
        var titles: [String: String] = [:]
        for case let sourceID? in cards.map(\.sourceID) where titles[sourceID] == nil {
            let title = vm.sourcesByID[sourceID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { titles[sourceID] = title }
        }
        return titles
    }
}

/// Holds the app awake while one answer is written: the write is a fetch
/// and a save, two round trips iOS could suspend the app between when it
/// goes to the background.
@MainActor
final class MobileBackgroundSaveAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // iOS calls this on the main thread when the time is up; an
            // assertion left open then is a kill, so it ends here.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let ending = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}

// MARK: - The screen

/// Today's card review, or a notebook's Practice: one card at a time, the
/// wording large, Show Answer, then the back, why it holds and its source,
/// and Forgot or Remembered (the Mac's `MemoryCardSessionView`, on a phone).
/// Today's review carries the scope in its title — All notebooks or one — and
/// its menu speaks today's review by voice and, when today's review chat from
/// before cards holds an answer, continues it. A card's source opens in the
/// Reader, pushed over the review, which waits where it was.
struct MobileCardReviewScreen: View {
    @StateObject private var session: MobileCardReviewSession
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var goal = MobileMemoryGoalModel.shared
    @ObservedObject private var live = MobileVoiceConversationController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDayChat = false
    /// Where VoiceOver goes next: the back once it is shown, the next card's
    /// wording once an answer moves on.
    @AccessibilityFocusState private var spoken: SpokenPart?

    private enum SpokenPart: Hashable {
        case prompt
        case back
    }

    /// The review's column on an iPad or a phone held sideways.
    private static let columnWidth: CGFloat = 600
    private static let topID = "memory.cards.top"

    init(mode: MobileCardReviewSession.Mode, opensAsPractice: Bool = false) {
        _session = StateObject(wrappedValue: MobileCardReviewSession(mode: mode, opensAsPractice: opensAsPractice))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await session.open() }
            // The day's goal clock runs while the review is on screen and the
            // app is in front; a tap keeps it running.
            .onAppear {
                goal.setSceneActive(scenePhase == .active)
                goal.present()
            }
            .onDisappear { goal.dismiss() }
            .onChange(of: scenePhase) { _, phase in goal.setSceneActive(phase == .active) }
            .simultaneousGesture(TapGesture().onEnded { goal.noteActivity() })
            .sensoryFeedback(.selection, trigger: session.revealCount)
            .sensoryFeedback(.impact(weight: .light), trigger: session.answerCount)
            .onChange(of: session.revealCount) { _, _ in spoken = .back }
            .onChange(of: session.answerCount) { _, _ in spoken = .prompt }
            .overlay {
                if let celebration = goal.celebration {
                    MemoryGoalCelebrationView(goalMinutes: celebration.goalMinutes, streak: celebration.streak) {
                        goal.acknowledgeCelebration(celebration.id)
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("memory.goalCelebration")
                }
            }
            .navigationDestination(isPresented: $showsDayChat) {
                MobileMemoryReviewChatScreen()
            }
            .accessibilityIdentifier("memory.cards")
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView()
                .accessibilityLabel("Dealing cards")
        case .empty:
            emptyState
        case .reviewing:
            if let sitting = session.sitting {
                reviewing(sitting)
            }
        }
    }

    // MARK: Title and menu

    private var scopeTitle: String {
        guard case .today(let scope) = session.mode else { return "" }
        return MobileCardReviewCopy.scopeTitle(scope, notebooks: vm.notebooks)
    }

    private var navigationTitle: String {
        switch session.mode {
        case .today: return scopeTitle
        case .notebookPractice(let notebookID):
            let title = vm.notebooks.first { $0.id == notebookID }?.title ?? ""
            return title.isEmpty ? "Practice" : "\(title) · Practice"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .today(let scope) = session.mode {
            ToolbarItem(placement: .principal) {
                scopeMenu(scope)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await live.startMemoryReview() }
                    } label: {
                        Label("Review by Voice", systemImage: "waveform")
                    }
                    .disabled(live.isActive)
                    if session.dayChatIsUnderway {
                        Button {
                            showsDayChat = true
                        } label: {
                            Label("Continue Today's Review Chat", systemImage: "text.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("memory.cards.more")
            }
        }
    }

    /// All notebooks or one, as the Mac's Memory scope menu. A notebook this
    /// phone lists no more (archived) stays in the menu while the review is
    /// narrowed to it.
    private func scopeMenu(_ scope: MemoryReviewScope) -> some View {
        let binding = Binding<MemoryReviewScope>(
            get: { scope },
            set: { session.changeScope($0) }
        )
        let listed = Set(vm.notebooks.map(\.id))
        return Menu {
            Picker("Cards From", selection: binding) {
                Text("All notebooks").tag(MemoryReviewScope.allNotebooks)
                if case .notebook(let id) = scope, !listed.contains(id) {
                    Text(scopeTitle).tag(scope)
                }
                ForEach(MobileNotebookOrdering.sorted(vm.notebooks, lastChatAt: vm.lastNotebookChatAt)) { notebook in
                    Text(notebook.title).tag(MemoryReviewScope.notebook(notebook.id))
                }
            }
        } label: {
            HStack(spacing: MobileDesign.Spacing.xSmall) {
                Text(scopeTitle)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Cards from")
        .accessibilityValue(scopeTitle)
        .accessibilityHint("Chooses every notebook or one")
        .accessibilityIdentifier("memory.cards.scope")
    }

    // MARK: Reviewing

    private func reviewing(_ sitting: MemoryCardSitting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    if sitting.isRoundOver {
                        endCard(sitting)
                    } else if let card = sitting.current {
                        progress(sitting)
                        cardView(card, sitting: sitting)
                    }
                    if let error = session.saveError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("memory.cards.saveError")
                    }
                }
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.large)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Each card starts at its top.
            .onChange(of: sitting.current?.itemID) { _, _ in
                proxy.scrollTo(Self.topID, anchor: .top)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !sitting.isRoundOver {
                    answerBar(sitting)
                }
            }
        }
    }

    /// "Card 3 of 18", how the round stands, and the bar.
    private func progress(_ sitting: MemoryCardSitting) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    progressCount(sitting)
                    Spacer(minLength: MobileDesign.Spacing.medium)
                    progressTally(sitting)
                }
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                    progressCount(sitting)
                    progressTally(sitting)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            ProgressView(value: sitting.progress)
                .tint(Color.accentColor)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.progress")
    }

    private func progressCount(_ sitting: MemoryCardSitting) -> some View {
        Text("Card \(sitting.cardNumber) of \(sitting.cardCount)")
    }

    @ViewBuilder
    private func progressTally(_ sitting: MemoryCardSitting) -> some View {
        if !sitting.results.isEmpty {
            Text("\(sitting.rememberedCount) remembered · \(sitting.forgottenCount) forgot")
        }
    }

    private func cardView(_ card: MemoryCardSitting.Card, sitting: MemoryCardSitting) -> some View {
        let shown = sitting.isAnswerShown
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                Text(session.currentSourceTitle ?? "Memory")
                    .font(.caption.weight(.semibold))
                    .kerning(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .accessibilityLabel(session.currentSourceTitle.map { "From \($0)" } ?? "Memory")
                Spacer(minLength: MobileDesign.Spacing.small)
                tags(card, sitting: sitting)
            }
            Text(card.prompt)
                .font(.system(.title2, design: .serif))
                .foregroundStyle(shown ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($spoken, equals: .prompt)
                .accessibilityIdentifier("memory.cards.prompt")
            if !card.frontImages.isEmpty {
                MobileMemoryCardImageGrid(images: card.frontImages, sourceID: card.sourceID)
            }
            if card.isFirstVariedServe, !sitting.isRepeat {
                Text("Worded differently on purpose — same answer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memory.cards.varied")
            }
            if shown {
                Divider()
                Text(card.back)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Answer: \(card.back)")
                    .accessibilityFocused($spoken, equals: .back)
                    .accessibilityIdentifier("memory.cards.back")
                if !card.backImages.isEmpty {
                    MobileMemoryCardImageGrid(images: card.backImages, sourceID: card.sourceID)
                }
                if !card.why.isEmpty {
                    Text("Why: " + card.why.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memory.cards.why")
                }
                if let sourceID = card.sourceID {
                    sourceChip(sourceID: sourceID)
                }
            }
        }
        .padding(MobileDesign.Spacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous)
        )
        .shadow(color: MobileDesign.elevatedShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.card")
    }

    @ViewBuilder
    private func tags(_ card: MemoryCardSitting.Card, sitting: MemoryCardSitting) -> some View {
        HStack(spacing: MobileDesign.Spacing.xSmall) {
            if let difficulty = card.difficulty {
                tag(difficulty.rawValue.uppercased(), tint: Self.tint(for: difficulty), heard: difficulty.rawValue.capitalized)
            }
            if card.isNew { tag("NEW", tint: .accentColor, heard: "New card") }
            if sitting.isRepeat { tag("AGAIN", tint: .secondary, heard: "Asked again") }
            if card.isVariant || card.alwaysAsk { wordingMenu(card) }
        }
    }

    /// How a card is worded, on a card asked in a rewording or one held to
    /// its own words, the Mac's card ⋯: "This Asks Something Else" takes the
    /// rewording out and asks the card in its own words; "Always Ask in Its
    /// Own Words" turns rewording off for the card, and "Let Its Wording
    /// Vary" on again (docs/memory-design.md, "Variations"). All Cards' menu
    /// carries the switch for any card.
    private func wordingMenu(_ card: MemoryCardSitting.Card) -> some View {
        Menu {
            if card.isVariant {
                Button("This Asks Something Else", systemImage: "arrow.uturn.backward") {
                    session.reportAskedSomethingElse()
                }
            }
            if card.alwaysAsk {
                Button("Let Its Wording Vary", systemImage: "shuffle") { session.setAlwaysAsk(false) }
            } else {
                Button("Always Ask in Its Own Words", systemImage: "text.quote") { session.setAlwaysAsk(true) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: MobileDesign.Metrics.minimumTouchTarget, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Wording")
        .accessibilityHint("How this card is worded")
        .accessibilityIdentifier("memory.cards.wording")
    }

    private func tag(_ text: String, tint: Color, heard: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, MobileDesign.Spacing.small)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel(heard)
    }

    private static func tint(for difficulty: MemoryCardDifficulty) -> Color {
        switch difficulty {
        case .easy: return .green
        case .medium: return .orange
        case .hard: return .red
        }
    }

    /// The card's source, opened in the Reader over the review, in the
    /// notebook the review is narrowed to.
    private func sourceChip(sourceID: String) -> some View {
        let title = session.sourceTitles[sourceID] ?? "Source"
        return NavigationLink(value: MobileShellRoute.source(sourceID, notebookID: session.notebookInScope)) {
            HStack(spacing: MobileDesign.Spacing.small) {
                // The picture the sources list draws for it, else a plain
                // document for a source the phone has not synced.
                if let source = vm.sourcesByID[sourceID] {
                    MobileSourceRowThumbnail(source: source)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "doc.text")
                        .font(.subheadline.weight(.medium))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .padding(.vertical, MobileDesign.Spacing.xSmall)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: MobileDesign.Radius.compact, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A pointer on an iPad lights it up like the buttons around it.
        .hoverEffect(.highlight)
        .accessibilityLabel("Source: \(title)")
        .accessibilityHint("Opens it in the Reader")
        .accessibilityIdentifier("memory.cards.source")
    }

    // MARK: Answers

    private func answerBar(_ sitting: MemoryCardSitting) -> some View {
        Group {
            if sitting.isAnswerShown {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: MobileDesign.Spacing.medium))
                    : AnyLayout(HStackLayout(spacing: MobileDesign.Spacing.medium))
                layout {
                    Button {
                        session.answer(remembered: false)
                    } label: {
                        Text("Forgot")
                            .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("memory.cards.forgot")
                    Button {
                        session.answer(remembered: true)
                    } label: {
                        Text("Remembered")
                            .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("memory.cards.remembered")
                }
            } else {
                Button {
                    session.showAnswer()
                } label: {
                    Text("Show Answer")
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("memory.cards.showAnswer")
            }
        }
        .font(.headline)
        .controlSize(.large)
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: The end of a round

    private func endCard(_ sitting: MemoryCardSitting) -> some View {
        let forgotten = sitting.forgottenCount
        let waiting = session.waitingCards.count
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Text(sitting.isRepeat ? "Forgotten cards, again" : "That's the round")
                .font(.system(.title2, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(MobileCardReviewCopy.roundSummary(
                cardCount: sitting.cardCount,
                remembered: sitting.rememberedCount,
                forgot: sitting.forgottenCount
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            VStack(spacing: MobileDesign.Spacing.medium) {
                if forgotten > 0 {
                    Button {
                        session.reviewForgotten()
                    } label: {
                        Text("Review Forgotten (\(forgotten))")
                            .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Asks them again; your first answers stand")
                    .accessibilityIdentifier("memory.cards.reviewForgotten")
                }
                if session.isReadingFollowup {
                    ProgressView()
                        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
                } else if waiting > 0 {
                    Button {
                        session.continueWithWaitingCards()
                    } label: {
                        Text("Continue (\(waiting) more)")
                            .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("memory.cards.continue")
                }
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("memory.cards.done")
            }
            .font(.headline)
            .controlSize(.large)
        }
        .padding(MobileDesign.Spacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: MobileDesign.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.end")
    }

    // MARK: Nothing to deal

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: MemoryReviewSession.sidebarIcon)
        } description: {
            Text(emptyDescription)
        } actions: {
            if session.practiceCount > 0 {
                Button(MobileCardReviewCopy.practiceNewCards(session.practiceCount)) {
                    session.startPractice()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("memory.cards.practiceNew")
            }
        }
        .accessibilityIdentifier("memory.cards.empty")
    }

    private var emptyTitle: String {
        switch session.mode {
        case .today: return "Nothing Due Today"
        case .notebookPractice: return "No Cards to Practice"
        }
    }

    private var emptyDescription: String {
        switch session.mode {
        case .today(.allNotebooks):
            return "Cards you keep come back here on the day they're due."
        case .today(.notebook):
            return "No card from \(scopeTitle) is due today."
        case .notebookPractice:
            return "Cards kept from this notebook's sources on your Mac are practiced here."
        }
    }
}

// MARK: - Card pictures

private struct MobileMemoryCardImageGrid: View {
    let images: [MemoryCardImage]
    /// The card's source, whose Source record carries the pictures drawn for
    /// its walk (`MobileSourceFileStore.walkthroughPicture`).
    let sourceID: String?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: MobileDesign.Spacing.small, alignment: .top), count: min(2, max(1, images.count)))
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ForEach(images, id: \.self) { image in
                MobileMemoryCardImageTile(image: image, sourceID: sourceID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.images")
    }
}

private struct MobileMemoryCardImageTile: View {
    let image: MemoryCardImage
    let sourceID: String?

    @State private var rendered: UIImage?
    @State private var didResolve = false

    var body: some View {
        Group {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .background(Color.white)
            } else if didResolve {
                Label("Picture unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityLabel(image.alt)
        .task(id: "\(sourceID ?? "")#\(image.target)") {
            if let generated = GeneratedImageReference(urlString: image.target) {
                // The phone keeps no image store: a drawn picture reaches it only
                // on the Source record beside the walk that shows it, so a card
                // whose source carries no such picture says it is unavailable.
                if let sourceID {
                    rendered = await MobileSourceFileStore.shared.walkthroughPicture(sourceID: sourceID, imageID: generated.id)
                }
            } else {
                rendered = await MobileMemoryCardImageRenderer.shared.data(for: image).flatMap(UIImage.init(data:))
            }
            didResolve = true
        }
    }
}

private actor MobileMemoryCardImageRenderer {
    static let shared = MobileMemoryCardImageRenderer()

    /// Data crosses the actor boundary rather than UIKit's non-Sendable image.
    func data(for image: MemoryCardImage) async -> Data? {
        guard let reference = SourceImageReference(urlString: image.target),
              case .page(let pageNumber) = reference.location,
              let url = try? await MobileSourceFileStore.shared.fetchPDF(sourceID: reference.sourceID, relativePath: nil),
              let document = PDFDocument(url: url),
              let page = document.page(at: pageNumber - 1) else { return nil }
        return Self.render(page: page, crop: reference.crop).pngData()
    }

    private static func render(page: PDFPage, crop: PaperFigureRect?) -> UIImage {
        guard let crop, crop.isValid else {
            return page.thumbnail(of: CGSize(width: 1_600, height: 2_100), for: .mediaBox)
        }
        let box = page.bounds(for: .mediaBox)
        let region = CGRect(
            x: box.minX + crop.x * box.width,
            y: box.maxY - (crop.y + crop.height) * box.height,
            width: crop.width * box.width,
            height: crop.height * box.height
        )
        let scale = min(8, 1_600 / max(1, region.width))
        let size = CGSize(width: region.width * scale, height: region.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: -region.minX * scale, y: (region.maxY * scale))
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
        }
    }
}
