import SwiftUI

/// The card review, in the window-filling memory focus (docs/memory-design.md,
/// "The card review"): one card at a time, the wording large, the learner's
/// answer typed or dictated on the card and Check, then their answer over
/// the back, the check's verdict on it under the fold, why it is right and
/// the source it quotes, and Forgot or Remembered, the verdict's grade first.
/// Show Answer opens the back with nothing typed, as a paper flashcard, and
/// the learner grades themselves (product owner, 2026-10-19).
///
/// It is drawn as a deck (docs/memory-design.md, "How a card
/// looks"; `MemoryCardChrome.swift`): over the card, the source it is from
/// and its place in the round, with a strip a segment a card; the card an
/// index card with the question set in the middle until the answer opens
/// under a fold; under it the edges of the cards still to come. An answered
/// card is tossed off toward its key's side (← Forgot, → Remembered) and the
/// next comes up off the deck. Check, Remembered and Done are the
/// Space's dark pill, the rest pale or bare, and each draws its key.
///
/// The window is the review's while it runs: the × is on the
/// chrome line (`MemoryReviewFocusChrome`). A card's source opens the
/// Reader beside the review without ending it (its own × closes it back to
/// the review alone). When the goal's minutes are met the celebration shows
/// here, as it showed in the chat.
///
/// Keys: Return in the answer field checks it (Shift-Return a new line),
/// Command-Return is Show Answer; once the back shows, Return takes the verdict's grade when the check has
/// one, ← or 1 is Forgot, → or 2 Remembered, D Go Deeper, ⌫ Delete Card.
/// They are off while the answer field is up, which takes the keys, while
/// the Reader is beside the review, which takes keys of its own, while a
/// draft is being edited, and while Go Deeper's panel is up, whose answer
/// field takes the keys.
///
/// **Go Deeper** (docs/memory-design.md, "Go Deeper on a card") answers the
/// card Remembered and puts a panel where the next card would be: the card it
/// is about, "GO DEEPER · THE PRINCIPLE" (or WHERE ELSE, WHAT WOULD PROVE IT
/// WRONG, WHAT IT'S LIKE), the question large in the card's serif, a field
/// for the answer (Return sends, Shift-Return a new line), then a short reply
/// under it, and Next Card, there from the start (→ or Return once the field
/// is gone). A question or a reply that fails is said in one line under the
/// panel, with Next Card still there.
///
/// A notebook's Practice also deals its cards to check: on such a draft the
/// bar is Forgot / Remembered / Skip (S) / Edit (E), and answering keeps it
/// (docs/memory-design.md, "Practice for a notebook").
struct MemoryCardSessionView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioChromeLineReservation) private var chromeReservation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: MemoryCardSessionModel
    /// The window's Reader, shown beside the review once a source chip asks.
    let reader: () -> AnyView

    /// The engagement clock's handle on this view (`present(owner:...)`).
    @State private var presenterToken = UUID()
    /// The draft whose editor is open (Edit, E).
    @State private var editingDraft: MemoryCardToCheck?
    /// The height Go Deeper's answer field's text needs.
    @State private var deeperFieldHeight: CGFloat = 0
    /// The side the card in front leaves to once it is answered: set before
    /// the answer, so the card goes the way its key points.
    @State private var exitEdge: HorizontalEdge = .trailing

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }
    private var sitting: MemoryCardSitting { session.sitting }
    private var keysEnabled: Bool {
        session.besideSourceID == nil && editingDraft == nil && session.deeper == nil && !takesAttempt
    }
    /// Whether the card on screen waits for the learner's answer: its field
    /// is up and takes the keys.
    private var takesAttempt: Bool {
        session.deeper == nil && sitting.current != nil && !sitting.isAnswerShown
    }

    /// The review's column, never narrower than a card reads at.
    private static let reviewMinimumWidth: CGFloat = 440
    private static let columnMaxWidth: CGFloat = 600
    /// A card is never shorter than this, so a short question sits in the
    /// middle of a card rather than on a strip of one.
    private static let cardMinimumHeight = MemoryCardMetrics.cardMinimumHeight

    var body: some View {
        GeometryReader { geo in
            let readerWidth = session.besideSourceID == nil
                ? 0
                : max(0, min(geo.size.width * 0.55, geo.size.width - Self.reviewMinimumWidth - 1))
            HStack(spacing: 0) {
                reviewColumn(height: geo.size.height)
                    .frame(width: geo.size.width - readerWidth - (readerWidth > 0 ? 1 : 0))
                if readerWidth > 0 {
                    StudioColumnHairline()
                    StudioPaneHost(activeTab: .reader, width: readerWidth) {
                        reader()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Reader")
                    .accessibilityIdentifier("memory.cards.reader")
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let celebration = goalTracker.celebration, celebration.sessionID == session.id {
                MemoryGoalCelebrationView(goalMinutes: celebration.goalMinutes, streak: celebration.streak) {
                    goalTracker.acknowledgeCelebration(celebration.id)
                }
                .transition(.opacity)
                .accessibilityIdentifier("memory.cards.celebration")
            }
        }
        .onAppear {
            goalTracker.present(owner: session, panel: presenterToken, sessionID: session.id, storage: vm.storage)
        }
        .onDisappear {
            goalTracker.dismiss(panel: presenterToken)
        }
        // Edit on a draft: kept in the learner's words, then answered as the
        // kept card it now is.
        .sheet(item: $editingDraft) { draft in
            MemoryCardToCheckEditorSheet(card: draft) { edit in
                session.keepCurrentDraft(edited: edit)
                editingDraft = nil
            } cancel: {
                editingDraft = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards")
    }

    // MARK: The review

    /// The column, a little under the top of a tall window: anchored there,
    /// not centred, so opening the answer never moves the question.
    private func reviewColumn(height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let deeper = session.deeper {
                    roundHeader
                    deeperPanel(deeper)
                    deeperFoot(deeper)
                } else if sitting.isRoundOver {
                    endCard
                } else if let card = sitting.current {
                    roundHeader
                    deck(card)
                    answerBar
                }
                if let error = session.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memory.cards.saveError")
                }
            }
            .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, min(max(height * 0.1, 44), 120))
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        // The ×, at the trailing edge of the review's own
        // column: beside the Reader the window's corner is the Reader's.
        .studioChromeLineHeader {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                MemoryReviewFocusChrome(
                    onTitlebarBand: titlebarBandHeight != nil,
                    controlSize: 28,
                    leavingEnds: session.leavingEndsSession
                        && MemoryReviewCommitment.leavingEndsSession(goalTracker.state),
                    identifierPrefix: "memory.cards.focus"
                ) {
                    vm.leaveMemoryReviewFocus(in: windowState)
                }
            }
            .padding(.horizontal, 14)
        }
        .environment(
            \.studioChromeLineReservation,
            session.besideSourceID == nil ? chromeReservation : StudioChromeLineReservation()
        )
    }

    /// Over the card: the source it is from, its place in the round, and
    /// the round a segment a card.
    private var roundHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(headerTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(placeLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .textSelection(.disabled)
            if session.deeper == nil {
                MemoryRoundStrip(marks: MemoryRoundStrip.marks(of: sitting))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.progress")
    }

    /// The card's source, or what the review is over when the library no
    /// longer names it.
    private var headerTitle: String {
        session.currentSourceTitle ?? session.scopeTitle
    }

    /// "3 of 18", with "Practice" or "Again" before it when the round is one;
    /// nothing while Go Deeper's panel stands where the next card would be.
    private var placeLine: String {
        let place = "\(sitting.cardNumber) of \(sitting.cardCount)"
        if session.deeper != nil { return "" }
        if sitting.isRepeat { return "Again · " + place }
        if sitting.kind == .practice { return "Practice · " + place }
        return place
    }

    // MARK: The card

    /// The card in front, the edges of those still to come under it, and
    /// the toss and the deal between them.
    private func deck(_ card: MemoryCardSitting.Card) -> some View {
        let remaining = max(0, sitting.cardCount - sitting.position - 1)
        return ZStack {
            cardView(card)
                .id("\(sitting.isRepeat)-\(sitting.position)-\(card.itemID)")
                .transition(.memoryCard(leavingTo: exitEdge, reduceMotion: reduceMotion))
        }
        .background(alignment: .bottom) {
            MemoryDeckEdges(remaining: remaining)
        }
        .padding(.bottom, MemoryDeckEdges.depth)
    }

    private func cardView(_ card: MemoryCardSitting.Card) -> some View {
        let shown = sitting.isAnswerShown
        let tags = Self.tags(of: card)
        // Every kept card carries its menu (Delete, and how it is worded); a
        // draft has Skip and Edit under it instead.
        let showsCardMenu = !card.isDraft
        // The top row takes room of its own only for tags or the wording
        // switch; the menu alone sits in the corner above the question.
        let hasTopRow = !tags.isEmpty || card.isVariant || card.alwaysAsk
        return VStack(alignment: .leading, spacing: 0) {
            let front = CardVisualization.split(card.prompt)
            Text(front.words.cardFaceText())
                .font(MemoryCardMetrics.frontFont)
                .foregroundStyle(shown ? Color.secondary : Color.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.prompt")
            if let html = front.html {
                MemoryCardVisualizationView(html: html)
                    .padding(.top, 16)
            }
            if !card.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.frontImages)
                    .padding(.top, 16)
            }
            if card.isFirstVariedServe, !sitting.isRepeat {
                Text("Worded differently on purpose — same answer.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                    .padding(.top, 10)
            }
            if !shown {
                attemptField
                    .padding(.top, 26)
            } else if let attempt = sitting.attempt {
                yourAnswer(attempt)
                    .padding(.top, 22)
            }
            if shown {
                answerFace(card)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, hasTopRow ? 52 : 34)
        .padding(.bottom, 32)
        // Until the answer opens, the question sits in the middle of the
        // card; then it rises to make room under the fold.
        .frame(maxWidth: .infinity, minHeight: Self.cardMinimumHeight, alignment: shown ? .topLeading : .leading)
        .overlay(alignment: .top) {
            if hasTopRow || showsCardMenu {
                HStack(spacing: 8) {
                    MemoryCardTagLine(tags: tags)
                    Spacer(minLength: 0)
                    if showsCardMenu { cardMenu(card) }
                }
                .padding(.leading, 34)
                .padding(.trailing, 20)
                .padding(.top, hasTopRow ? 18 : 10)
            }
        }
        .memoryCardSurface()
        .animation(.easeOut(duration: 0.22), value: shown)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.card")
    }

    /// The learner's answer, written on the card under the question: Return
    /// checks it, Shift-Return starts a new line (the chat composer's text
    /// view), and the mic dictates into it. It takes the keys the
    /// review's shortcuts would otherwise answer.
    private var attemptField: some View {
        let draft = Binding(get: { session.attemptDraft }, set: { session.attemptDraft = $0 })
        return MemoryCardAttemptBox(
            text: draft,
            onSubmit: { session.checkAttempt() },
            identifier: "memory.cards.attempt"
        )
    }

    /// Once checked, what the learner answered, over the fold, to grade
    /// against the back under it.
    private func yourAnswer(_ attempt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MemoryCardTagLine(tags: ["Your answer"])
            Text(attempt)
                .font(.system(size: 16))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.yourAnswer")
    }

    /// Under the fold: the answer, its pictures, why it holds, and the
    /// source it quotes.
    private func answerFace(_ card: MemoryCardSitting.Card) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryCardFold()
                .padding(.vertical, 22)
            if let check = sitting.answerCheck {
                MemoryCardVerdictLine(check: check)
                    .padding(.bottom, 16)
            }
            let back = CardVisualization.split(card.back)
            Text(back.words.cardFaceText())
                .font(MemoryCardMetrics.backFont)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.back")
            if let html = back.html {
                MemoryCardVisualizationView(html: html)
                    .padding(.top, 16)
            }
            if !card.backImages.isEmpty {
                MemoryCardImageGrid(images: card.backImages)
                    .padding(.top, 16)
            }
            if !card.why.isEmpty {
                MemoryCardWhyLine(why: card.why)
                    .padding(.top, 14)
            }
            // Every source the card stands on, its own first.
            let sources = (card.sourceID.map { [($0, card.quote)] } ?? []) + card.alsoFrom.map { ($0.sourceID, Optional($0.quote)) }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        sourceLink(sourceID: source.0, quote: source.1)
                    }
                }
                .padding(.top, 22)
            }
        }
    }

    /// "NEW", "TO CHECK": what kind of card this is, in its ink.
    private static func tags(of card: MemoryCardSitting.Card) -> [String] {
        var tags: [String] = []
        if card.isDraft { tags.append("To check") }
        if card.isNew { tags.append("New") }
        return tags
    }

    /// The kept card's ⋯ menu. How it is worded, on a card asked in a
    /// rewording or one the learner asked to keep in its own words: "This
    /// Asks Something Else" takes the rewording out of the card's rotation and
    /// asks the card in its own words; "Always Ask in Its Own Words" turns
    /// rewording off for the card, and "Let Its Wording Vary" on again
    /// (docs/memory-design.md, "Variations"). All Cards' menu carries the
    /// switch for any card. Then Delete Card (⌫ once the back shows): the
    /// card leaves the deck, with Undo at the foot of the window
    /// (`StudioViewModel.deleteCardFromReview`).
    private func cardMenu(_ card: MemoryCardSitting.Card) -> some View {
        Menu {
            if card.isVariant {
                Button("This Asks Something Else") { session.reportAskedSomethingElse() }
                    .help("Take this rewording out and ask the card in its own words")
            }
            if card.isVariant || card.alwaysAsk {
                if card.alwaysAsk {
                    Button("Let Its Wording Vary") { session.setAlwaysAsk(false) }
                } else {
                    Button("Always Ask in Its Own Words") { session.setAlwaysAsk(true) }
                }
                Divider()
            }
            Button("Delete Card", systemImage: "trash", role: .destructive) { deleteCard() }
                .accessibilityIdentifier("memory.cards.delete")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .help("Delete this card, or change how it is worded")
        .accessibilityLabel("Card")
        .accessibilityIdentifier("memory.cards.wording")
    }

    /// The card's source at the card's foot, drawn as the sources list draws
    /// one: its picture (cover, first page, artwork, else its kind's symbol),
    /// its title, a chevron. It opens the Reader beside the review, at the
    /// passage the card quotes. Its menu sends the source to another window
    /// instead.
    private func sourceLink(sourceID: String, quote: String?) -> some View {
        let title = session.sourceTitles[sourceID] ?? "Source"
        let article = vm.articlesById[vm.canonicalSourceID(sourceID)]
        return HStack(spacing: 0) {
            Button {
                Task { await vm.openCardSourceBesideReview(sourceID: sourceID, quote: quote, in: windowState) }
            } label: {
                HStack(spacing: 9) {
                    if let article {
                        // A book chapter shows the book's cover, as every other
                        // source list does through `bookCoverPaths`.
                        let bookCoverPath = article.sourceType == .book
                            ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                            : nil
                        SourceThumbnail(source: article, size: 24, bookCoverPath: bookCoverPath)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "doc.text")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
            .help("Open \(title) beside the review, at the passage this card quotes")
            .accessibilityLabel("Source: \(title)")
            .contextMenu {
                OtherWindowSourceMenuItem(sourceID: sourceID)
            }
            .accessibilityIdentifier("memory.cards.source")
            Spacer(minLength: 0)
        }
    }

    // MARK: Answers

    @ViewBuilder
    private var answerBar: some View {
        let draft = sitting.current?.draft
        VStack(spacing: 12) {
            if sitting.isAnswerShown {
                gradeButtons
                    .disabled(session.isKeepingDraft)
                // The arrow of the verdict's side still answers when Return
                // took its button.
                if keysEnabled, !session.isKeepingDraft, let verdict = sitting.verdictRemembers {
                    if verdict {
                        hiddenKey(.rightArrow) { answer(remembered: true) }
                    } else {
                        hiddenKey(.leftArrow) { answer(remembered: false) }
                    }
                }
                // Remembered, then a question past it, in place of the next
                // card: quieter than the two answers, never in their way. Not
                // offered on an answer the check found partly right or wrong.
                if session.offersGoDeeper, sitting.verdictRemembers != false {
                    MemoryReviewButton(
                        title: "Go Deeper",
                        key: keysEnabled ? "D" : nil,
                        kind: .quiet,
                        shortcut: keysEnabled ? KeyboardShortcut("d", modifiers: []) : nil
                    ) {
                        session.goDeeper()
                    }
                    .help(keysEnabled ? "Remembered — then a question that goes past it (D)" : "Remembered — then a question that goes past it")
                    .disabled(session.isKeepingDraft)
                    .accessibilityIdentifier("memory.cards.goDeeper")
                }
                // The number keys answer too, from the same row.
                if keysEnabled, !session.isKeepingDraft {
                    hiddenShortcut("1") { answer(remembered: false) }
                    hiddenShortcut("2") { answer(remembered: true) }
                    // ⌫ deletes a kept card (its ⋯ menu's Delete Card).
                    if draft == nil {
                        hiddenKey(.delete) { deleteCard() }
                    }
                }
            } else {
                // An answer to check, or Show Answer to turn the card with
                // nothing typed and grade it yourself.
                HStack(spacing: 12) {
                    MemoryReviewButton(
                        title: "Show Answer",
                        key: session.besideSourceID == nil ? "⌘↩" : nil,
                        kind: .secondary,
                        minWidth: 170,
                        shortcut: session.besideSourceID == nil ? KeyboardShortcut(.return, modifiers: .command) : nil
                    ) {
                        session.showAnswerUnanswered()
                    }
                    .help("Turn the card without typing, and grade yourself (⌘Return)")
                    .accessibilityIdentifier("memory.cards.showAnswer")
                    MemoryReviewButton(
                        title: "Check",
                        key: session.besideSourceID == nil ? "↩" : nil,
                        kind: .primary,
                        minWidth: 170
                    ) {
                        session.checkAttempt()
                    }
                    .disabled(session.attemptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Check your answer against the card (Return)")
                    .accessibilityIdentifier("memory.cards.check")
                }
            }
            // A card to check, in a notebook's Practice: answering keeps it,
            // Skip drops it for good, Edit keeps it in the learner's words.
            if let draft {
                HStack(spacing: 6) {
                    MemoryReviewButton(
                        title: "Skip",
                        key: keysEnabled ? "S" : nil,
                        kind: .quiet,
                        shortcut: keysEnabled ? KeyboardShortcut("s", modifiers: []) : nil
                    ) {
                        exitEdge = .leading
                        withAnimation(Self.dealAnimation) { session.skipCurrentDraft() }
                    }
                    .help(keysEnabled ? "Skip this card for good (S)" : "Skip this card for good")
                    .accessibilityIdentifier("memory.cards.skip")
                    MemoryReviewButton(
                        title: "Edit",
                        key: keysEnabled ? "E" : nil,
                        kind: .quiet,
                        shortcut: keysEnabled ? KeyboardShortcut("e", modifiers: []) : nil
                    ) {
                        editingDraft = draft
                    }
                    .help(keysEnabled ? "Keep this card in your own words (E)" : "Keep this card in your own words")
                    .accessibilityIdentifier("memory.cards.edit")
                }
                .disabled(session.isKeepingDraft)
                Text("Answering keeps this card.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Forgot and Remembered once the back shows, as the check left them
    /// (docs/memory-design.md, "The answer is checked"). With a verdict, its
    /// grade is the dark pill and Return confirms it; the other side is the
    /// override, "I Was Wrong" or "I Was Right", on its arrow. While the
    /// check runs both are pale and either grades at once; with no verdict
    /// (the check failed, or none was asked) they are Forgot and Remembered
    /// as the learner's own grade. ← and →, 1 and 2 always answer Forgot and
    /// Remembered.
    private var gradeButtons: some View {
        let verdict = sitting.verdictRemembers
        let checking = sitting.answerCheck == .checking
        return HStack(spacing: 12) {
            MemoryReviewButton(
                title: verdict == true ? "I Was Wrong" : "Forgot",
                key: keysEnabled ? (verdict == false ? "↩" : "←") : nil,
                kind: verdict == false ? .primary : .secondary,
                minWidth: 170,
                shortcut: keysEnabled
                    ? KeyboardShortcut(verdict == false ? .return : .leftArrow, modifiers: [])
                    : nil
            ) {
                answer(remembered: false)
            }
            .help(Self.gradeHelp(remembered: false, verdict: verdict, keys: keysEnabled))
            .accessibilityIdentifier("memory.cards.forgot")
            MemoryReviewButton(
                title: verdict == false ? "I Was Right" : "Remembered",
                key: keysEnabled ? (verdict == true ? "↩" : "→") : nil,
                kind: verdict == true || (verdict == nil && !checking) ? .primary : .secondary,
                minWidth: 170,
                shortcut: keysEnabled
                    ? KeyboardShortcut(verdict == true ? .return : .rightArrow, modifiers: [])
                    : nil
            ) {
                answer(remembered: true)
            }
            .help(Self.gradeHelp(remembered: true, verdict: verdict, keys: keysEnabled))
            .accessibilityIdentifier("memory.cards.remembered")
        }
    }

    private static func gradeHelp(remembered: Bool, verdict: Bool?, keys: Bool) -> String {
        let arrow = remembered ? "→ or 2" : "← or 1"
        switch (verdict, remembered) {
        case (true?, true), (false?, false):
            let title = remembered ? "Remembered, as the check found" : "Forgot, as the check found"
            return keys ? "\(title) (Return, \(arrow))" : title
        case (true?, false):
            return keys ? "The check was wrong: Forgot (\(arrow))" : "The check was wrong: Forgot"
        case (false?, true):
            return keys ? "The check was wrong: Remembered (\(arrow))" : "The check was wrong: Remembered"
        default:
            let title = remembered ? "Remembered" : "Forgot"
            return keys ? "\(title) (\(arrow))" : title
        }
    }

    private static let dealAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// Answers the card in front, tossing it toward its key's side. The side
    /// is set a turn before the answer, so the leaving card has it when the
    /// deal removes it.
    private func answer(remembered: Bool) {
        guard sitting.isAnswerShown, !session.isKeepingDraft else { return }
        exitEdge = remembered ? .trailing : .leading
        DispatchQueue.main.async {
            withAnimation(Self.dealAnimation) { session.answer(remembered: remembered) }
        }
    }

    /// Delete Card: the card in front leaves to the left, as a card no longer
    /// in the deck, and the next comes up; Undo at the window's foot puts it
    /// back.
    private func deleteCard() {
        guard sitting.current?.isDraft == false, !session.isKeepingDraft else { return }
        exitEdge = .leading
        DispatchQueue.main.async {
            withAnimation(Self.dealAnimation) { vm.deleteCardFromReview(session) }
        }
    }

    /// A key that answers with no button of its own on screen.
    private func hiddenShortcut(_ key: Character, action: @escaping () -> Void) -> some View {
        hiddenKey(KeyEquivalent(key), action: action)
    }

    private func hiddenKey(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: [])
            .buttonStyle(.hoverWash)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: Go Deeper

    /// Where the next card would be: the card Go Deeper answered, its
    /// question, the learner's answer and the reply.
    private func deeperPanel(_ deeper: MemoryCardSessionModel.Deeper) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The card it is about: its front muted, its back.
            VStack(alignment: .leading, spacing: 6) {
                Text(CardVisualization.words(deeper.card.prompt))
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CardVisualization.words(deeper.card.back))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("memory.cards.deeper.card")
            MemoryCardFold()
                .padding(.vertical, 20)
            VStack(alignment: .leading, spacing: 16) {
                switch deeper.stage {
                case .writingQuestion:
                    deeperWorkingLine("Writing a question")
                case .noQuestion:
                    if deeper.failure == nil {
                        Text("Nothing to go deeper on here: this card is a fact to keep.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.disabled)
                            .accessibilityIdentifier("memory.cards.deeper.noQuestion")
                    }
                case .asking(let question):
                    deeperQuestion(question)
                    deeperAnswerField
                case .replying(let question, let answer):
                    deeperQuestion(question)
                    deeperQuotedAnswer(answer)
                    deeperWorkingLine("Reading your answer")
                case .replied(let question, let answer, let reply):
                    deeperQuestion(question)
                    deeperQuotedAnswer(answer)
                    Text(reply)
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("memory.cards.deeper.reply")
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.deeper")
    }

    /// "GO DEEPER · THE PRINCIPLE", and the question large in the card's serif.
    private func deeperQuestion(_ question: MemoryUnderstandingProbe.CardQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryCardTagLine(tags: ["Go Deeper", question.kind.eyebrow])
                .accessibilityIdentifier("memory.cards.deeper.kind")
            Text(question.text)
                .font(MemoryCardMetrics.frontFont)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.deeper.question")
        }
    }

    /// The answer field: Return sends, Shift-Return starts a new line (the
    /// chat composer's text view, which keeps both), and it takes the keys
    /// the review's own shortcuts would otherwise answer.
    private var deeperAnswerField: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let draft = Binding(get: { session.deeperDraft }, set: { session.deeperDraft = $0 })
        let isEmpty = session.deeperDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .trailing, spacing: 10) {
            ReviewChatComposerTextView(
                text: draft,
                onSubmit: { session.sendDeeperAnswer() },
                autoFocus: true,
                onHeightChange: { deeperFieldHeight = $0 }
            )
            .frame(height: min(max(deeperFieldHeight, 34), 160))
            .overlay(alignment: .topLeading) {
                if session.deeperDraft.isEmpty {
                    Text("Your answer")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                        .textSelection(.disabled)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(Color.primary.opacity(0.035)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityLabel("Your answer")
            .accessibilityIdentifier("memory.cards.deeper.answer")
            MemoryReviewButton(title: "Send", key: "↩", kind: .primary, minWidth: 90) {
                session.sendDeeperAnswer()
            }
            .disabled(isEmpty)
            .help("Send your answer (Return)")
            .accessibilityIdentifier("memory.cards.deeper.send")
        }
    }

    private func deeperQuotedAnswer(_ answer: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 2)
            Text(answer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.deeper.yourAnswer")
    }

    private func deeperWorkingLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.deeper.working")
    }

    /// Under the panel: a failure in one line, and Next Card, there from the
    /// start so the question is never a gate. Its keys (→, Return) wait for
    /// the answer field to go.
    @ViewBuilder
    private func deeperFoot(_ deeper: MemoryCardSessionModel.Deeper) -> some View {
        let keyed = !deeper.takesAnswer && session.besideSourceID == nil && editingDraft == nil
        let settled: Bool = {
            switch deeper.stage {
            case .replied, .noQuestion: return true
            case .writingQuestion, .asking, .replying: return false
            }
        }()
        if let failure = deeper.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.deeper.failure")
        }
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            MemoryReviewButton(
                title: "Next Card",
                key: keyed ? "→" : nil,
                kind: settled ? .primary : .secondary,
                minWidth: 170,
                shortcut: keyed ? KeyboardShortcut(.rightArrow, modifiers: []) : nil
            ) {
                session.leaveDeeper()
            }
            .help(keyed ? "Next Card (→ or Return)" : "Next Card")
            .accessibilityIdentifier("memory.cards.deeper.next")
            // Return too, from behind the button so it takes no room
            // and Next Card stays centred.
            .background {
                if keyed {
                    Button("", action: session.leaveDeeper)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.hoverWash)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The end of a round

    /// How the round went: a line, the round's strip with every answer in
    /// it, and what comes next.
    private var endCard: some View {
        let forgotten = sitting.forgottenCount
        let waiting = session.waitingCards.count
        return VStack(alignment: .leading, spacing: 0) {
            Text(endTitle)
                .font(.system(size: 28, weight: .regular, design: .serif))
            Text(endSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 6)
            MemoryRoundStrip(marks: MemoryRoundStrip.marks(of: sitting), height: 6)
                .padding(.top, 22)
            HStack(spacing: 10) {
                if forgotten > 0 {
                    MemoryReviewButton(title: "Review Forgotten (\(forgotten))", kind: .secondary) {
                        withAnimation(Self.dealAnimation) { session.reviewForgotten() }
                    }
                    .accessibilityIdentifier("memory.cards.reviewForgotten")
                }
                if session.isReadingFollowup {
                    ProgressView().controlSize(.small)
                } else if waiting > 0 {
                    MemoryReviewButton(title: "Continue (\(waiting) more)", kind: .secondary) {
                        withAnimation(Self.dealAnimation) { session.continueWithWaitingCards() }
                    }
                    .accessibilityIdentifier("memory.cards.continue")
                }
                Spacer(minLength: 0)
                MemoryReviewButton(
                    title: "Done",
                    key: keysEnabled ? "↩" : nil,
                    kind: .primary,
                    minWidth: 110,
                    shortcut: keysEnabled ? .defaultAction : nil
                ) {
                    vm.leaveMemoryReviewFocus(in: windowState)
                }
                .accessibilityIdentifier("memory.cards.done")
            }
            .padding(.top, 30)
        }
        .textSelection(.disabled)
        .padding(.horizontal, 34)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCardSurface()
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.end")
    }

    private var endTitle: String {
        if case .done = goalTracker.state, !session.isReadingFollowup, session.waitingCards.isEmpty {
            return "Today's review is done"
        }
        return sitting.isRepeat ? "Forgotten cards, again" : "That's the round"
    }

    private var endSummary: String {
        let count = sitting.cardCount
        let cards = count == 1 ? "1 card" : "\(count) cards"
        let skipped = sitting.skippedCount
        return "\(cards) · \(sitting.rememberedCount) remembered · \(sitting.forgottenCount) forgot"
            + (skipped > 0 ? " · \(skipped) skipped" : "")
    }
}

/// The learner's answer box on a card, as the chat's composer draws it: the
/// field, and under it the mic and the model that will check the answer
/// (product owner, 2026-10-26: "you can just copy paste that text box from the
/// chat app"). Return checks, Shift-Return starts a new line.
///
/// The mic is the chat's: it opens a recording that the dictation model from
/// Settings → Voice transcribes (`ReviewDictationService`). Stop puts the words
/// in the field and checks them, as the chat's stop sends; the × puts them in
/// the field and leaves the check to the learner. The model chip is the
/// `card_answer_check` route, the same one Settings → AI Models sets.
struct MemoryCardAttemptBox: View {
    @Binding var text: String
    let onSubmit: () -> Void
    var autoFocus = true
    var onCancel: (() -> Void)? = nil
    /// The overlay's smaller box (the knowledge map's review).
    var isCompact = false
    let identifier: String

    @StateObject private var dictation = ReviewDictationService()
    @State private var fieldHeight: CGFloat = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isCompact ? 9 : 12, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 2) {
            field
            controls
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 2 : 4)
        .background(shape.fill(Color.primary.opacity(isCompact ? 0.04 : 0.035)))
        .overlay(shape.strokeBorder(Color.primary.opacity(isCompact ? 0.12 : 0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your answer")
        .accessibilityIdentifier(identifier)
        .onDisappear { dictation.cancelRecording() }
    }

    private var field: some View {
        ReviewChatComposerTextView(
            text: $text,
            onSubmit: onSubmit,
            autoFocus: autoFocus,
            onCancel: onCancel,
            onHeightChange: { fieldHeight = $0 }
        )
        .frame(height: min(max(fieldHeight, isCompact ? 30 : 34), isCompact ? 120 : 160))
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text("Type or dictate your answer")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, ReviewChatComposerTextView.overlayTextLeadingInset)
                    .padding(.top, isCompact ? 6 : 7)
                    .allowsHitTesting(false)
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The chat's row under its field: the model and the mic on the trailing
    /// edge, and the recording's meter over the whole row while the mic is open.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if dictation.isRecording {
                ReviewDictationWaveform(
                    meter: dictation.meter,
                    onStop: { finishDictation(thenCheck: true) },
                    onKeepInDraft: { finishDictation(thenCheck: false) }
                )
            } else {
                Spacer(minLength: 0)
                InlineModelPicker(task: .cardAnswerCheck)
                    .layoutPriority(1)
                if dictation.isTranscribing {
                    ReviewDictationTranscribingIndicator()
                } else {
                    Button {
                        Task { await dictation.startRecording() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
                    .help("Dictate answer")
                    .accessibilityLabel("Dictate answer")
                    .accessibilityIdentifier("\(identifier).dictate")
                }
            }
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottomLeading) {
            if let failure = dictation.errorMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Stops the mic and puts what was said after what was typed.
    private func finishDictation(thenCheck: Bool) {
        Task { @MainActor in
            guard let said = await dictation.stopAndTranscribe(), !said.isEmpty else { return }
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = typed.isEmpty ? said : "\(text)\n\(said)"
            if thenCheck { onSubmit() }
        }
    }
}
