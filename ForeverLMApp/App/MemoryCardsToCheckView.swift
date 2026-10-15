import SwiftUI

/// The Memory pane's **To Check** (docs/memory-design.md, "Cards to check"):
/// the cards drafted from sources and not yet gone through, and the items from
/// before cards, offered once, in the scope the pane's (every notebook, or
/// one: a notebook's Studio Cards row opens it narrowed to the notebook, in
/// the notebook's document slot).
///
/// A card at a time, as Review deals them (since 2026-10-12; product owner,
/// at the list of every card with its buttons: "more intuitive if the review
/// process just shows cards that i go through … and then i can say keep /
/// edit etc"): over the card, the source it is from, which opens it, its
/// place ("3 of 15") and the strip of the cards gone through; the card drawn
/// as Review draws one — the deck's paper, its difficulty, the front in the
/// review's serif — with the edges of the cards still to come under it.
///
/// A card is asked before it is judged (product owner, 2026-10-15: "even for
/// 'to check' cards i should still be quizzed on them; not just see the
/// answer"): the front waits for the learner's answer, typed or said, or "I
/// Don't Know", as Review's does, and only then turns to the fold, the back,
/// why and Show Passage, with **Skip**, **Edit** and **Keep** under it. The
/// answer is not graded and not stored: it is there to be set against the
/// back. Skip and Edit stay within reach before it, for a card that is wrong
/// on its face.
///
/// - **Keep** makes it a card of Memory (`keepMemoryCard`) and goes off to
///   the right, **Skip** drops it for good and goes off to the left, **Edit**
///   keeps it in the learner's words. With the pane focused K, E and S do the
///   same, and Return keeps.
/// - The ⋯ over the card: **Keep All** and **Skip All** for the rest of the
///   card's source (Skip All asks first when it would retire cards from
///   before), and the source's own menu.
///
/// Nothing is written until the learner decides; a decided card leaves at
/// once and comes back only if storage refused it. A draft is offered for 14
/// days after it was drafted, which is computed on reading, never written.
/// The pane claims keys only while it has focus: inside a notebook it sits
/// beside the chat, whose typing is the composer's, so it takes focus when it
/// opens only when a chat did not open it at one of its cards.
struct MemoryCardsToCheckView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pane's read of the scope's cards to check, in their order.
    let cards: [MemoryCardToCheck]
    let hasLoaded: Bool

    /// Cards decided and on their way to storage, hidden meanwhile.
    @State private var decided: Set<String> = []
    /// What this sitting decided, in order: kept or not. The strip and the
    /// count read it; a card storage refused leaves it.
    @State private var gone: [Gone] = []
    /// The card in front, when the learner (or a chat's card) chose one;
    /// otherwise the first that waits.
    @State private var selection: String?
    @State private var editing: MemoryCardToCheck?
    @State private var confirmingSkipAll: [MemoryCardToCheck]?
    /// Where the card in front goes once decided: Keep to the right, Skip to
    /// the left, as Review's Remembered and Forgot.
    @State private var exitEdge: HorizontalEdge = .trailing
    /// What the learner has written for the card in front, until they check it.
    @State private var attemptDraft = ""
    /// The card in front once its back shows, and the answer that opened it
    /// (nil for "I Don't Know"). Nothing here is written to storage.
    @State private var openCard: Revealed?
    /// The height the answer field's text needs.
    @State private var attemptFieldHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private struct Revealed: Equatable {
        let cardID: String
        let attempt: String?
    }

    private struct Gone: Equatable {
        let cardID: String
        let kept: Bool
    }

    /// The column the card reads in, Review's.
    private static let columnMaxWidth: CGFloat = 600
    private static let dealAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    private var visible: [MemoryCardToCheck] { cards.filter { !decided.contains($0.cardID) } }

    /// The answer the card in front was opened with; nil while it waits for one.
    private func opened(_ card: MemoryCardToCheck) -> Revealed? {
        openCard?.cardID == card.cardID ? openCard : nil
    }

    private var current: MemoryCardToCheck? {
        let visible = visible
        if let selection, let card = visible.first(where: { $0.cardID == selection }) { return card }
        return visible.first
    }

    var body: some View {
        let visible = visible
        GeometryReader { geo in
            Group {
                if let card = current {
                    column(height: geo.size.height) { sitting(card, waiting: visible.count) }
                } else if hasLoaded, !gone.isEmpty {
                    column(height: geo.size.height) { doneState }
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: CharacterSet(charactersIn: "kesKES"), phases: .down) { press in
            handleKey(press.characters.lowercased()) ? .handled : .ignored
        }
        .onKeyPress(.return) { handleKey("k") ? .handled : .ignored }
        .onChange(of: cards.map(\.cardID)) { _, ids in
            // A fresh read: what storage refused is back, what it wrote is gone.
            let present = Set(ids)
            decided.formIntersection(present)
            if let selection, !present.contains(selection) { self.selection = nil }
            takeFocusCard()
        }
        .onAppear {
            // Opened at a chat's card, the chat beside it keeps its composer.
            if windowState?.memoryPaneFocusCardID == nil { focused = true }
            takeFocusCard()
        }
        .onChange(of: windowState?.memoryPaneFocusCardID) { _, _ in takeFocusCard() }
        .onChange(of: current?.cardID) { _, _ in
            // Another card in front starts with an empty answer.
            attemptDraft = ""
            openCard = nil
        }
        .sheet(item: $editing) { card in
            MemoryCardToCheckEditorSheet(card: card) { edit in
                editing = nil
                decide(card, .keepEdited(edit))
            } cancel: {
                editing = nil
            }
        }
        .alert(
            "Skip the rest of this source's cards?",
            isPresented: Binding(
                get: { confirmingSkipAll != nil },
                set: { if !$0 { confirmingSkipAll = nil } }
            ),
            presenting: confirmingSkipAll
        ) { cards in
            Button("Skip All", role: .destructive) {
                decideAll(cards, keep: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cards from before cards are retired and never asked again.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.pane.toCheck")
    }

    /// Review's column: centred, a little under the top of a tall pane, so a
    /// longer card never moves the source line over it.
    private func column<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, min(max(height * 0.08, 28), 96))
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        // A click anywhere in the pane gives it the keys.
        .simultaneousGesture(TapGesture().onEnded { focused = true })
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasLoaded {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Nothing to check")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    /// Every card gone through: what became of them.
    private var doneState: some View {
        let kept = gone.filter(\.kept).count
        return VStack(alignment: .leading, spacing: 8) {
            Text("All checked")
                .font(.title2.weight(.semibold))
            Text(Self.doneLine(kept: kept, skipped: gone.count - kept))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.pane.toCheck.done")
    }

    /// "You kept 9 cards and skipped 3. Review will ask the ones you kept."
    static func doneLine(kept: Int, skipped: Int) -> String {
        let keptCards = kept == 1 ? "1 card" : "\(kept) cards"
        switch (kept, skipped) {
        case (0, _): return "You skipped them all."
        case (_, 0): return "You kept \(keptCards). Review will ask them."
        default: return "You kept \(keptCards) and skipped \(skipped). Review will ask the ones you kept."
        }
    }

    // MARK: The card in front

    private func sitting(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        Group {
            header(card, waiting: waiting)
            deck(card, waiting: waiting)
            actions(card)
            if gone.isEmpty {
                // What the buttons do, to someone who has never seen them.
                Text("Answer the card, then keep it and Review will ask it, or skip it and it is gone.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("memory.pane.toCheck.hint")
            }
        }
    }

    /// Over the card: its source, which opens it, its place in what waits,
    /// the ⋯ for its source, and the strip of the cards gone through.
    private func header(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        let title = sourceTitle(card.sourceID)
        let article = vm.articlesById[vm.canonicalSourceID(card.sourceID)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    openSource(card.sourceID)
                } label: {
                    HStack(spacing: 9) {
                        sourceThumbnail(article)
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 8, inset: -5))
                .help("Open \(title)")
                .contextMenu { sourceMenu(card.sourceID) }
                .accessibilityLabel("Source: \(title)")
                .accessibilityIdentifier("memory.pane.toCheck.source")
                Spacer(minLength: 12)
                Text("\(gone.count + 1) of \(gone.count + waiting)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .textSelection(.disabled)
                    .accessibilityIdentifier("memory.pane.toCheck.place")
                sourceActionsMenu(card)
            }
            MemoryRoundStrip(
                marks: gone.map { $0.kept ? .remembered : .skipped }
                    + [.current]
                    + Array(repeating: .upcoming, count: max(0, waiting - 1))
            )
        }
    }

    /// The rest of the card's source at once, and the source's own menu.
    private func sourceActionsMenu(_ card: MemoryCardToCheck) -> some View {
        let rest = visible.filter { $0.sourceID == card.sourceID }
        let count = rest.count == 1 ? "1 card" : "\(rest.count) cards"
        return Menu {
            Section("\(count) from this source") {
                Button("Keep All") { decideAll(rest, keep: true) }
                Button("Skip All") {
                    if rest.contains(where: { $0.kind == .legacy }) {
                        confirmingSkipAll = rest
                    } else {
                        decideAll(rest, keep: false)
                    }
                }
            }
            Divider()
            sourceMenu(card.sourceID)
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
        .help("Keep or skip the rest of this source's cards")
        .accessibilityLabel("More")
        .accessibilityIdentifier("memory.pane.toCheck.more")
    }

    /// The source's picture as every source list draws it: its cover, first
    /// page or artwork, else its kind's symbol; a book chapter the book's.
    @ViewBuilder
    private func sourceThumbnail(_ article: StudioArticle?) -> some View {
        if let article {
            let bookCoverPath = article.sourceType == .book
                ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                : nil
            SourceThumbnail(source: article, size: 24, bookCoverPath: bookCoverPath)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
                .accessibilityHidden(true)
        }
    }

    /// The card in front, the edges of those still to come under it, and
    /// the toss and the deal between them.
    private func deck(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        ZStack {
            MemoryCardToCheckFace(
                card: card,
                opened: opened(card).map { MemoryCardToCheckFace.Opened(attempt: $0.attempt) },
                attempt: $attemptDraft,
                attemptFieldHeight: $attemptFieldHeight,
                autoFocusAttempt: windowState?.memoryPaneFocusCardID == nil,
                submit: { reveal(card) },
                showPassage: passage(of: card).map { quote in { openSource(card.sourceID, passage: quote) } }
            )
            .id(card.cardID)
            .transition(.memoryCard(leavingTo: exitEdge, reduceMotion: reduceMotion))
            .contextMenu {
                if opened(card) != nil { Button("Keep") { decide(card, .keep) } }
                Button("Edit…") { editing = card }
                Button("Skip") { decide(card, .skip) }
                Divider()
                sourceMenu(card.sourceID)
            }
            .accessibilityAction(named: "Keep") { if opened(card) != nil { decide(card, .keep) } }
            .accessibilityAction(named: "Edit") { editing = card }
            .accessibilityAction(named: "Skip") { decide(card, .skip) }
        }
        .background(alignment: .bottom) {
            MemoryDeckEdges(remaining: waiting - 1)
        }
        .padding(.bottom, MemoryDeckEdges.depth)
    }

    /// Before the answer: I Don't Know and Check, as Review's, with Skip and
    /// Edit quiet under them. After it: Skip and Edit, pale; Keep, the dark
    /// pill that moves on.
    @ViewBuilder
    private func actions(_ card: MemoryCardToCheck) -> some View {
        let keys = focused && editing == nil
        if opened(card) != nil {
            HStack(spacing: 10) {
                MemoryReviewButton(title: "Skip", key: keys ? "S" : nil, kind: .secondary, minWidth: 110) {
                    decide(card, .skip)
                }
                .help("Drop this card for good (S)")
                .accessibilityIdentifier("memory.pane.toCheck.skip")
                MemoryReviewButton(title: "Edit", key: keys ? "E" : nil, kind: .secondary, minWidth: 110) {
                    focused = true
                    editing = card
                }
                .help("Keep this card in your own words (E)")
                .accessibilityIdentifier("memory.pane.toCheck.edit")
                MemoryReviewButton(title: "Keep", key: keys ? "K" : nil, kind: .primary, minWidth: 180) {
                    decide(card, .keep)
                }
                .help("Keep this card: Review will ask it (K or Return)")
                .accessibilityIdentifier("memory.pane.toCheck.keep")
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    MemoryReviewButton(title: "I Don't Know", kind: .secondary, minWidth: 170) {
                        revealNotKnown(card)
                    }
                    .help("Show the answer")
                    .accessibilityIdentifier("memory.pane.toCheck.notKnown")
                    MemoryReviewButton(title: "Check", key: "↩", kind: .primary, minWidth: 170) {
                        reveal(card)
                    }
                    .disabled(trimmedAttempt.isEmpty)
                    .help("Show the answer beside yours (Return)")
                    .accessibilityIdentifier("memory.pane.toCheck.check")
                }
                HStack(spacing: 6) {
                    MemoryReviewButton(title: "Skip", kind: .quiet) { decide(card, .skip) }
                        .help("Drop this card for good")
                        .accessibilityIdentifier("memory.pane.toCheck.skip")
                    MemoryReviewButton(title: "Edit", kind: .quiet) {
                        focused = true
                        editing = card
                    }
                    .help("Keep this card in your own words")
                    .accessibilityIdentifier("memory.pane.toCheck.edit")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var trimmedAttempt: String { attemptDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Turns the card to its back on what the learner wrote. A blank answer
    /// turns nothing: the back is never a free flip.
    private func reveal(_ card: MemoryCardToCheck) {
        let answer = trimmedAttempt
        guard !answer.isEmpty else { return }
        open(card, attempt: answer)
    }

    /// "I Don't Know": the back shows with no answer beside it.
    private func revealNotKnown(_ card: MemoryCardToCheck) {
        open(card, attempt: nil)
    }

    private func open(_ card: MemoryCardToCheck, attempt: String?) {
        guard opened(card) == nil else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            openCard = Revealed(cardID: card.cardID, attempt: attempt)
        }
        // The answer field gave the keys up; K, E and S are the pane's again.
        focused = true
    }

    @ViewBuilder
    private func sourceMenu(_ sourceID: String) -> some View {
        Button("Open Source") { openSource(sourceID) }
        OtherWindowSourceMenuItem(sourceID: sourceID)
    }

    /// The passage a card quotes, when it names one.
    private func passage(of card: MemoryCardToCheck) -> String? {
        guard let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { return nil }
        return quote
    }

    /// The Reader beside the pane, at the passage a card quotes when it
    /// names one.
    private func openSource(_ sourceID: String, passage: String? = nil) {
        Task { await vm.openLinkedSourceInReader(sourceID, passage: passage, beside: .memory) }
    }

    // MARK: Deciding

    private func decide(_ card: MemoryCardToCheck, _ action: MemoryCardTriageAction) {
        let kept: Bool
        if case .skip = action { kept = false } else { kept = true }
        exitEdge = kept ? .trailing : .leading
        decide([MemoryCardTriageDecision(card: card, action: action)])
    }

    /// Keep All or Skip All on the rest of a source's cards.
    private func decideAll(_ cards: [MemoryCardToCheck], keep: Bool) {
        exitEdge = keep ? .trailing : .leading
        decide(keep
            ? MemoryCardTriage.keepAll(cards)
            : cards.map { MemoryCardTriageDecision(card: $0, action: .skip) })
    }

    /// Hides the decided cards at once, deals the next card in front, and
    /// writes the decisions; a card storage refused comes back.
    private func decide(_ decisions: [MemoryCardTriageDecision]) {
        guard !decisions.isEmpty else { return }
        focused = true
        let ids = Set(decisions.map(\.card.cardID))
        let front = current?.cardID
        let order = visible.map(\.cardID)
        withAnimation(Self.dealAnimation) {
            if let front, ids.contains(front) {
                // The next card after the one in front, else the first still waiting.
                selection = order.drop { $0 != front }.dropFirst().first { !ids.contains($0) }
            }
            decided.formUnion(ids)
            gone += decisions.map { decision in
                if case .skip = decision.action { return Gone(cardID: decision.card.cardID, kept: false) }
                return Gone(cardID: decision.card.cardID, kept: true)
            }
        }
        Task {
            let result = await vm.triageCardsToCheck(decisions)
            let failed = Set(result.failed.map(\.cardID))
            guard !failed.isEmpty else { return }
            decided.subtract(failed)
            gone.removeAll { failed.contains($0.cardID) }
        }
    }

    /// The card a chat's saved cards were opened at
    /// (`StudioWindowState.memoryPaneFocusCardID`): dealt in front. The pane
    /// keeps the keys it had: the chat beside it keeps its composer.
    private func takeFocusCard() {
        guard let windowState, let id = windowState.memoryPaneFocusCardID else { return }
        if visible.contains(where: { $0.cardID == id }) {
            selection = id
            windowState.memoryPaneFocusCardID = nil
        } else if hasLoaded {
            // Gone through already, or not in this scope: nothing to point at.
            windowState.memoryPaneFocusCardID = nil
        }
    }

    /// K, E and S (and Return, which keeps) on the card in front, once its
    /// back shows: before that the keys are the answer's.
    private func handleKey(_ key: String) -> Bool {
        guard editing == nil, confirmingSkipAll == nil, let card = current, opened(card) != nil else { return false }
        switch key {
        case "k":
            decide(card, .keep)
        case "e":
            editing = card
        case "s":
            decide(card, .skip)
        default:
            return false
        }
        return true
    }

    private func sourceTitle(_ sourceID: String) -> String {
        let title = vm.articlesById[vm.canonicalSourceID(sourceID)]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Source not in the library" : title
    }
}

// MARK: - A card to check

/// One card to check, drawn as Review draws a card: the deck's paper, its
/// difficulty (or that it is from before cards), the front in the review's
/// serif and its pictures. Until the learner answers, the field for the
/// answer is all that is under the front; once they have (or said they do
/// not know), the learner's answer, the fold, the back, why it holds and
/// Show Passage follow.
private struct MemoryCardToCheckFace: View {
    /// A card whose back is showing, and the answer that opened it (nil when
    /// the learner said they did not know).
    struct Opened: Equatable {
        let attempt: String?
    }

    let card: MemoryCardToCheck
    /// Nil while the card waits for an answer.
    let opened: Opened?
    @Binding var attempt: String
    @Binding var attemptFieldHeight: CGFloat
    /// Whether the answer field takes the keys when the card is dealt: not
    /// when a chat opened the pane at this card and keeps its composer.
    let autoFocusAttempt: Bool
    /// Return in the answer field.
    let submit: () -> Void
    /// Opens the source at the passage the card quotes; nil when it quotes none.
    let showPassage: (() -> Void)?

    private var tags: [String] {
        [card.face.difficulty?.rawValue, card.kind == .legacy ? "From before cards" : nil].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tags.isEmpty {
                MemoryCardTagLine(tags: tags)
                    .padding(.bottom, 16)
            }
            Text(card.face.front)
                .font(MemoryCardMetrics.frontFont)
                .foregroundStyle(opened == nil ? Color.primary : Color.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.pane.toCheck.front")
            if !card.face.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.face.frontImages)
                    .padding(.top, 16)
            }
            if let opened {
                if let given = opened.attempt {
                    yourAnswer(given)
                        .padding(.top, 22)
                }
                answerFace
                    .transition(.opacity)
            } else {
                attemptField
                    .padding(.top, 26)
            }
        }
        .textSelection(.disabled)
        .padding(.horizontal, 34)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(
            maxWidth: .infinity,
            minHeight: MemoryCardMetrics.cardMinimumHeight,
            alignment: opened == nil ? .leading : .topLeading
        )
        .memoryCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.pane.toCheck.card")
    }

    /// The learner's answer, as Review's card takes it: Return checks it,
    /// Shift-Return starts a new line, and macOS dictation speaks into it.
    private var attemptField: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ReviewChatComposerTextView(
            text: $attempt,
            onSubmit: submit,
            autoFocus: autoFocusAttempt,
            onHeightChange: { attemptFieldHeight = $0 }
        )
        .frame(height: min(max(attemptFieldHeight, 34), 160))
        .overlay(alignment: .topLeading) {
            if attempt.isEmpty {
                Text("Type or dictate your answer")
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
        .accessibilityIdentifier("memory.pane.toCheck.attempt")
    }

    private func yourAnswer(_ given: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MemoryCardTagLine(tags: ["Your answer"])
            Text(given)
                .font(.system(size: 16))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.pane.toCheck.yourAnswer")
    }

    /// Under the fold: the back, its pictures, why it holds, Show Passage.
    private var answerFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryCardFold()
                .padding(.vertical, 22)
            Text(card.face.back)
                .font(MemoryCardMetrics.backFont)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.pane.toCheck.back")
            if !card.face.backImages.isEmpty {
                MemoryCardImageGrid(images: card.face.backImages)
                    .padding(.top, 16)
            }
            if !card.face.why.isEmpty {
                MemoryCardWhyLine(why: card.face.why)
                    .padding(.top, 14)
            }
            if let showPassage {
                Button(action: showPassage) {
                    Label("Show Passage", systemImage: "text.quote")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, tint: .secondary))
                .help("Open the source at the passage this card stands on")
                .accessibilityIdentifier("memory.pane.toCheck.passage")
                .padding(.top, 20)
            }
        }
    }
}

// MARK: - Editing a card to check

/// A card to check's front, back and why, kept in the learner's words. For a
/// draft, Keep keeps the edited card. For a card from before cards, which is
/// kept already, a new front alone rewords it, and a new back or why starts
/// it over — which the sheet says before it keeps (docs/memory-design.md,
/// "Cards: identity and Keep").
struct MemoryCardToCheckEditorSheet: View {
    let card: MemoryCardToCheck
    let keep: (MemoryCardEdit) -> Void
    let cancel: () -> Void

    @State private var front: String
    @State private var back: String
    @State private var why: String
    @State private var confirmingStartOver = false

    init(card: MemoryCardToCheck, keep: @escaping (MemoryCardEdit) -> Void, cancel: @escaping () -> Void) {
        self.card = card
        self.keep = keep
        self.cancel = cancel
        _front = State(initialValue: card.face.front)
        _back = State(initialValue: card.face.back)
        _why = State(initialValue: card.face.why.joined(separator: "\n"))
    }

    private var edit: MemoryCardEdit {
        MemoryCardEdit(
            front: front.trimmingCharacters(in: .whitespacesAndNewlines),
            back: back.trimmingCharacters(in: .whitespacesAndNewlines),
            why: why.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            frontImages: card.face.frontImages,
            backImages: card.face.backImages
        )
    }

    /// A card from before cards whose back or why changed is started over.
    private var startsOver: Bool {
        card.kind == .legacy && (edit.back != card.face.back || edit.why != card.face.why)
    }

    var body: some View {
        MemoryCardEditorForm(
            front: $front,
            back: $back,
            why: $why,
            primaryTitle: "Keep",
            canSave: !edit.front.isEmpty && !edit.back.isEmpty,
            cancel: cancel
        ) {
            if startsOver {
                confirmingStartOver = true
            } else {
                keep(edit)
            }
        }
        .alert("Start this card over?", isPresented: $confirmingStartOver) {
            Button("Start Over") { keep(edit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new answer makes a new card, first asked tomorrow. Its answers so far stay with the old one.")
        }
        .accessibilityIdentifier("memory.pane.toCheck.editor")
    }
}
