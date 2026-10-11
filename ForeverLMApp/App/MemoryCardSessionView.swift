import SwiftUI

/// The card review, in the window-filling memory focus (docs/memory-design.md,
/// "The card review"): one card at a time, the wording large, Show Answer,
/// then the back, why it is right and the source it quotes, and Forgot or
/// Remembered. The layout is the flashcard player's mockup
/// (design-mockups/memory-card-review.svg): an eyebrow naming the source, the
/// card's place in the round with a bar, the card, and two answers with
/// their keys.
///
/// The window is the review's while it runs: the × is on the
/// chrome line (`MemoryReviewFocusChrome`). A card's source chip opens the
/// Reader beside the review without ending it (its own × closes it back to
/// the review alone). When the goal's minutes are met the celebration shows
/// here, as it showed in the chat.
///
/// Keys: Space shows the answer; ← or 1 is Forgot, → or 2 Remembered, D Go
/// Deeper. They are off while the Reader is beside the review, which takes
/// keys of its own, while a draft is being edited, and while Go Deeper's
/// panel is up, whose answer field takes the keys.
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

    let session: MemoryCardSessionModel
    /// The window's Reader, shown beside the review once a source chip asks.
    let reader: () -> AnyView

    /// The engagement clock's handle on this view (`present(owner:...)`).
    @State private var presenterToken = UUID()
    /// The draft whose editor is open (Edit, E).
    @State private var editingDraft: MemoryCardToCheck?
    /// The height Go Deeper's answer field's text needs.
    @State private var deeperFieldHeight: CGFloat = 0

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }
    private var sitting: MemoryCardSitting { session.sitting }
    private var keysEnabled: Bool { session.besideSourceID == nil && editingDraft == nil && session.deeper == nil }

    /// The review's column, never narrower than a card reads at.
    private static let reviewMinimumWidth: CGFloat = 440
    private static let columnMaxWidth: CGFloat = 580
    private static let cardCornerRadius: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let readerWidth = session.besideSourceID == nil
                ? 0
                : max(0, min(geo.size.width * 0.55, geo.size.width - Self.reviewMinimumWidth - 1))
            HStack(spacing: 0) {
                reviewColumn
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

    private var reviewColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                if let deeper = session.deeper {
                    deeperPanel(deeper)
                    deeperFoot(deeper)
                } else if sitting.isRoundOver {
                    endCard
                } else if let card = sitting.current {
                    progressRow
                    cardView(card)
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
            .padding(.top, 48)
            .padding(.bottom, 32)
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

    /// "MEMORY · <source>", and what the review is over.
    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: MemoryReviewSession.sidebarIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .textSelection(.disabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.heading")
    }

    private var eyebrow: String {
        guard let source = session.currentSourceTitle, !sitting.isRoundOver || session.deeper != nil else { return "MEMORY" }
        return "MEMORY · " + source.uppercased()
    }

    private var subtitle: String {
        sitting.kind == .practice ? "\(session.scopeTitle) · Practice" : session.scopeTitle
    }

    /// "Card 3 of 18", how the round stands, and the bar.
    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Card \(sitting.cardNumber) of \(sitting.cardCount)")
                Spacer(minLength: 12)
                if !sitting.results.isEmpty {
                    Text("\(sitting.rememberedCount) remembered · \(sitting.forgottenCount) forgot")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.disabled)
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, bar.size.width * sitting.progress))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.2), value: sitting.progress)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.progress")
    }

    // MARK: The card

    private func cardView(_ card: MemoryCardSitting.Card) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        let showsWordingMenu = card.isVariant || card.alwaysAsk
        return VStack(alignment: .leading, spacing: 16) {
            if card.difficulty != nil || card.isNew || card.isDraft || sitting.isRepeat || showsWordingMenu {
                HStack(spacing: 6) {
                    if let difficulty = card.difficulty {
                        tag(difficulty.rawValue.uppercased(), tint: Self.tint(for: difficulty))
                    }
                    if card.isNew { tag("NEW", tint: .accentColor) }
                    if card.isDraft { tag("TO CHECK", tint: .teal) }
                    if sitting.isRepeat { tag("AGAIN", tint: .secondary) }
                    Spacer(minLength: 0)
                    if showsWordingMenu { wordingMenu(card) }
                }
            }
            Text(card.prompt)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(sitting.isAnswerShown ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.prompt")
            if !card.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.frontImages)
            }
            if card.isFirstVariedServe, !sitting.isRepeat {
                Text("Worded differently on purpose — same answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sitting.isAnswerShown {
                Divider()
                Text(card.back)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memory.cards.back")
                if !card.backImages.isEmpty {
                    MemoryCardImageGrid(images: card.backImages)
                }
                if !card.why.isEmpty {
                    Text("Why: " + card.why.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sourceID = card.sourceID {
                    sourceChip(sourceID: sourceID, quote: card.quote)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
        )
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.card")
    }

    /// How a card is worded, on a card asked in a rewording or one the
    /// learner asked to keep in its own words: "This Asks Something Else"
    /// takes the rewording out of the card's rotation and asks the card in
    /// its own words; "Always Ask in Its Own Words" turns rewording off for
    /// the card, and "Let Its Wording Vary" on again (docs/memory-design.md,
    /// "Variations"). All Cards' menu carries the switch for any card.
    private func wordingMenu(_ card: MemoryCardSitting.Card) -> some View {
        Menu {
            if card.isVariant {
                Button("This Asks Something Else") { session.reportAskedSomethingElse() }
                    .help("Take this rewording out and ask the card in its own words")
            }
            if card.alwaysAsk {
                Button("Let Its Wording Vary") { session.setAlwaysAsk(false) }
            } else {
                Button("Always Ask in Its Own Words") { session.setAlwaysAsk(true) }
            }
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
        .help("How this card is worded")
        .accessibilityLabel("Wording")
        .accessibilityIdentifier("memory.cards.wording")
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .textSelection(.disabled)
    }

    private static func tint(for difficulty: MemoryCardDifficulty) -> Color {
        switch difficulty {
        case .easy: return .green
        case .medium: return .orange
        case .hard: return .red
        }
    }

    /// The card's source, drawn as the sources list draws one: its picture
    /// (cover, first page, artwork, else its kind's symbol), its title, a
    /// chevron. It opens the Reader beside the review, at the passage the card
    /// quotes. Its menu sends the source to another window instead.
    private func sourceChip(sourceID: String, quote: String?) -> some View {
        let title = session.sourceTitles[sourceID] ?? "Source"
        let article = vm.articlesById[vm.canonicalSourceID(sourceID)]
        return Button {
            Task { await vm.openCardSourceBesideReview(sourceID: sourceID, quote: quote, in: windowState) }
        } label: {
            HStack(spacing: 10) {
                if let article {
                    // A book chapter shows the book's cover, as every other
                    // source list does through `bookCoverPaths`.
                    let bookCoverPath = article.sourceType == .book
                        ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                        : nil
                    SourceThumbnail(source: article, size: 30, bookCoverPath: bookCoverPath)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "doc.text")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0, opacity: 0.08))
        .help("Open \(title) beside the review, at the passage this card quotes")
        .accessibilityLabel("Source: \(title)")
        .contextMenu {
            OtherWindowSourceMenuItem(sourceID: sourceID)
        }
        .accessibilityIdentifier("memory.cards.source")
    }

    // MARK: Answers

    @ViewBuilder
    private var answerBar: some View {
        let draft = sitting.current?.draft
        VStack(spacing: 10) {
            if sitting.isAnswerShown {
                HStack(spacing: 16) {
                    answerButton("Forgot", key: "←", prominent: false, shortcut: .leftArrow) {
                        session.answer(remembered: false)
                    }
                    .accessibilityIdentifier("memory.cards.forgot")
                    answerButton("Remembered", key: "→", prominent: true, shortcut: .rightArrow) {
                        session.answer(remembered: true)
                    }
                    .accessibilityIdentifier("memory.cards.remembered")
                }
                .disabled(session.isKeepingDraft)
                // Remembered, then a question past it, in place of the next
                // card: quieter than the two answers, never in their way.
                if session.offersGoDeeper {
                    quietCapsuleButton("Go Deeper", key: keysEnabled ? "D" : nil) { session.goDeeper() }
                        .keyboardShortcut(keysEnabled ? KeyboardShortcut("d", modifiers: []) : nil)
                        .help(keysEnabled ? "Remembered — then a question that goes past it (D)" : "Remembered — then a question that goes past it")
                        .accessibilityLabel("Go Deeper")
                        .disabled(session.isKeepingDraft)
                        .accessibilityIdentifier("memory.cards.goDeeper")
                }
                // The number keys answer too, from the same row.
                if keysEnabled, !session.isKeepingDraft {
                    hiddenShortcut("1") { session.answer(remembered: false) }
                    hiddenShortcut("2") { session.answer(remembered: true) }
                }
            } else {
                answerButton("Show Answer", key: "Space", prominent: true, shortcut: .space) {
                    session.showAnswer()
                }
                .accessibilityIdentifier("memory.cards.showAnswer")
            }
            // A card to check, in a notebook's Practice: answering keeps it,
            // Skip drops it for good, Edit keeps it in the learner's words.
            if let draft {
                HStack(spacing: 10) {
                    draftButton("Skip", key: "s") { session.skipCurrentDraft() }
                        .help(keysEnabled ? "Skip this card for good (S)" : "Skip this card for good")
                        .accessibilityIdentifier("memory.cards.skip")
                    draftButton("Edit", key: "e") { editingDraft = draft }
                        .help(keysEnabled ? "Keep this card in your own words (E)" : "Keep this card in your own words")
                        .accessibilityIdentifier("memory.cards.edit")
                }
                .disabled(session.isKeepingDraft)
                Text("Answering keeps this card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Skip or Edit on a draft: a quieter capsule, its key beside its title.
    private func draftButton(_ title: String, key: Character, action: @escaping () -> Void) -> some View {
        capsuleButton(title, key: keysEnabled ? String(key).uppercased() : nil, prominent: false, minWidth: 90, action: action)
            .keyboardShortcut(keysEnabled ? KeyboardShortcut(KeyEquivalent(key), modifiers: []) : nil)
            .accessibilityLabel(title)
    }

    private func answerButton(
        _ title: String,
        key: String,
        prominent: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        capsuleButton(title, key: keysEnabled ? key : nil, prominent: prominent, minWidth: 150, action: action)
            .keyboardShortcut(keysEnabled ? KeyboardShortcut(shortcut, modifiers: []) : nil)
            .help(keysEnabled ? "\(title) (\(key))" : title)
            // The key beside the title is for the eye; VoiceOver says the
            // answer alone.
            .accessibilityLabel(title)
    }

    /// The review's own buttons: a capsule, filled for the one that moves
    /// on, with the key that presses it beside its title.
    private func capsuleButton(
        _ title: String,
        key: String? = nil,
        prominent: Bool,
        minWidth: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let key {
                    Text(key)
                        .font(.caption.weight(.medium))
                        .opacity(0.7)
                }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(minWidth: minWidth, minHeight: 36)
            .padding(.horizontal, 16)
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: prominent ? 0.18 : 0.08))
    }

    /// A third way to answer, quieter than Forgot and Remembered: smaller, no
    /// fill, a faint edge, still washed under the pointer.
    private func quietCapsuleButton(_ title: String, key: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let key {
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .opacity(0.7)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, minHeight: 28)
            .padding(.horizontal, 12)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.08))
    }

    /// A key that answers with no button of its own on screen.
    private func hiddenShortcut(_ key: Character, action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .keyboardShortcut(KeyEquivalent(key), modifiers: [])
            .buttonStyle(.hoverWash)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: Go Deeper

    /// Where the next card would be: the card Go Deeper answered, its
    /// question, the learner's answer and the reply.
    private func deeperPanel(_ deeper: MemoryCardSessionModel.Deeper) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 16) {
            // The card it is about: its front muted, its back.
            VStack(alignment: .leading, spacing: 6) {
                Text(deeper.card.prompt)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(deeper.card.back)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("memory.cards.deeper.card")
            Divider()
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
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("memory.cards.deeper.reply")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
        )
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.deeper")
    }

    /// "GO DEEPER · THE PRINCIPLE", and the question large in the card's serif.
    private func deeperQuestion(_ question: MemoryUnderstandingProbe.CardQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GO DEEPER · " + question.kind.eyebrow)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.accentColor)
                .textSelection(.disabled)
                .accessibilityIdentifier("memory.cards.deeper.kind")
            Text(question.text)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.cards.deeper.question")
        }
    }

    /// The answer field: Return sends, Shift-Return starts a new line (the
    /// chat composer's text view, which keeps both), and it takes the keys
    /// the review's own shortcuts would otherwise answer.
    private var deeperAnswerField: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let draft = Binding(get: { session.deeperDraft }, set: { session.deeperDraft = $0 })
        let isEmpty = session.deeperDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .trailing, spacing: 8) {
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
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityLabel("Your answer")
            .accessibilityIdentifier("memory.cards.deeper.answer")
            capsuleButton("Send", prominent: true, minWidth: 70) { session.sendDeeperAnswer() }
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
            capsuleButton("Next Card", key: keyed ? "→" : nil, prominent: settled, minWidth: 150) {
                session.leaveDeeper()
            }
            .keyboardShortcut(keyed ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
            .help(keyed ? "Next Card (→ or Return)" : "Next Card")
            .accessibilityLabel("Next Card")
            .accessibilityIdentifier("memory.cards.deeper.next")
            if keyed {
                Button("", action: session.leaveDeeper)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.hoverWash)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The end of a round

    private var endCard: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        let forgotten = sitting.forgottenCount
        let waiting = session.waitingCards.count
        return VStack(alignment: .leading, spacing: 14) {
            Text(endTitle)
                .font(.system(size: 22, weight: .regular, design: .serif))
            Text(endSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 10) {
                if forgotten > 0 {
                    capsuleButton("Review Forgotten (\(forgotten))", prominent: false) { session.reviewForgotten() }
                        .accessibilityIdentifier("memory.cards.reviewForgotten")
                }
                if session.isReadingFollowup {
                    ProgressView().controlSize(.small)
                } else if waiting > 0 {
                    capsuleButton("Continue (\(waiting) more)", prominent: false) { session.continueWithWaitingCards() }
                        .accessibilityIdentifier("memory.cards.continue")
                }
                Spacer(minLength: 0)
                capsuleButton("Done", prominent: true, minWidth: 90) { vm.leaveMemoryReviewFocus(in: windowState) }
                    .keyboardShortcut(keysEnabled ? .defaultAction : nil)
                    .accessibilityIdentifier("memory.cards.done")
            }
        }
        .textSelection(.disabled)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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
