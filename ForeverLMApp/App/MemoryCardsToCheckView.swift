import SwiftUI

/// The Memory pane's **To Check** (docs/memory-design.md, "Cards to check"):
/// the cards drafted from sources and not yet gone through, and the items from
/// before cards, offered once, in the scope the pane's (every notebook, or
/// one: a notebook's Studio Cards row opens it narrowed to the notebook, in
/// a pane of the notebook's window).
///
/// A card at a time, as Review deals them (since 2026-10-12; product owner,
/// at the list of every card with its buttons: "more intuitive if the review
/// process just shows cards that i go through … and then i can say keep /
/// edit etc"): over the card, the source it is from, which opens it, its
/// place ("3 of 15") and the strip of the cards gone through; the card drawn
/// as Review draws one — the deck's paper, the front in the review's
/// serif — with the edges of the cards still to come under it.
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
/// once and comes back only if storage refused it. A draft waits until the
/// learner keeps or skips it; it never expires.
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
    /// Every card id this sitting has seen, in the order it first met them.
    @State private var dealt: [String] = []
    /// What this sitting decided, in order: kept or not. The strip and the
    /// count read it; a card storage refused leaves it.
    @State private var gone: [Gone] = []
    /// The card in front, when the learner (or a chat's card) chose one;
    /// otherwise the first that waits.
    @State private var selection: String?
    @State private var editing: MemoryCardToCheck?
    /// The other sources the learner took off a card before deciding it, by
    /// card id: the card is kept on the rest. The card's own source stays.
    @State private var droppedSources: [String: Set<String>] = [:]
    /// The sources popover of the card in front is open.
    @State private var isListingSources = false
    /// Where the card in front goes once decided: Keep to the right, Skip to
    /// the left, as Review's Remembered and Forgot.
    @State private var exitEdge: HorizontalEdge = .trailing
    /// What the learner has written for the card in front, until they check it.
    @State private var attemptDraft = ""
    /// The card in front once its back shows, and the answer that opened it
    /// (nil for "I Don't Know"). Nothing here is written to storage.
    @State private var openCard: Revealed?
    /// The pictures drawn for cards this sitting, by card id, until the card is
    /// decided: a Keep carries it, a Skip drops it. Never written before.
    @State private var drawn: [String: MemoryCardImage] = [:]
    /// The cards whose picture is being drawn.
    @State private var drawing: Set<String> = []
    @State private var drawFailure: String?
    /// Where the check of the answer that opened a card stands, by card id:
    /// the same Card Answer Check Review runs (product owner, 2026-10-16: "it
    /// should actually grade my answer here! in these cards"). The verdict
    /// only says how the answer did; Keep and Skip stay the decisions, and
    /// nothing of the check is written.
    @State private var checks: [String: MemoryCardSitting.AnswerCheck] = [:]
    @State private var checkWork: Task<Void, Never>?
    /// Decisions taken and not yet written, oldest first: Back takes the
    /// newest one back (product owner, 2026-10-16: "if i click the wrong thing;
    /// i need to be able to go back here"). They are written once the learner
    /// has been still for `holdSeconds`, when the pane closes, or when the app
    /// goes to the background; a Back after that has nothing to take back.
    @State private var held: [Held] = []
    @State private var flushWork: Task<Void, Never>?
    @FocusState private var focused: Bool

    private struct Revealed: Equatable {
        let cardID: String
        let attempt: String?
    }

    private struct Held {
        let id = UUID()
        let decisions: [MemoryCardTriageDecision]
        /// The source this decision removed from the library, when it did;
        /// its own Undo brings it back.
        let removedSourceID: String?
    }

    /// How long a decision waits for a Back before it is written.
    private static let holdSeconds: UInt64 = 30

    private struct Gone: Equatable {
        let cardID: String
        let kept: Bool
    }

    /// The column the card reads in, Review's.
    private static let columnMaxWidth: CGFloat = 600
    private static let dealAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// The cards in the order this sitting dealt them. A card another agent
    /// adds while the pane is open (a re-read puts it anywhere in the pane's
    /// order) waits at the back, so the card in front and the next one stay
    /// what the learner was looking at.
    private var ordered: [MemoryCardToCheck] {
        guard !dealt.isEmpty else { return cards }
        let rank = Dictionary(dealt.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return cards.enumerated()
            .sorted { (rank[$0.element.cardID] ?? Int.max, $0.offset) < (rank[$1.element.cardID] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// The cards waiting, each with the pictures put on it since it was dealt:
    /// those a chat beside the pane added (`update_card`), then the one drawn.
    private var visible: [MemoryCardToCheck] {
        ordered.filter { !decided.contains($0.cardID) }.map { card in
            var card = card
            if let held = windowState?.memoryCardPictures[card.cardID] {
                card = card.replacingImages(front: held.front, back: held.back)
            }
            return drawn[card.cardID].map { card.addingBackImage($0) } ?? card
        }
    }

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
            let known = Set(dealt)
            dealt += ids.filter { !known.contains($0) }
            decided.formIntersection(present)
            if let selection, !present.contains(selection) { self.selection = nil }
            takeFocusCard()
        }
        .onAppear {
            // The card waits for an answer, so the answer field takes the keys
            // when it is dealt (and not at all when a chat opened the pane at a
            // card: the chat beside it keeps its composer). Claiming them here
            // as well raced the field and left it unable to type.
            if dealt.isEmpty { dealt = cards.map(\.cardID) }
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
            "Couldn't draw the picture",
            isPresented: Binding(get: { drawFailure != nil }, set: { if !$0 { drawFailure = nil } })
        ) {
            Button("OK") { drawFailure = nil }
        } message: {
            Text(drawFailure ?? "")
        }
        // The card in front is what a chat beside the pane is asked about:
        // every message from it carries the card (`ChatContextAdditions.cardFraming`).
        .onChange(of: onScreenCard, initial: true) { _, card in
            windowState?.memoryCardOnScreen = card
        }
        .onChange(of: Set(visible.map(\.cardID)), initial: true) { _, waiting in
            windowState?.memoryCardsWaitingIDs = waiting
        }
        .onDisappear {
            flushHeld()
            windowState?.memoryCardOnScreen = nil
            windowState?.memoryCardsWaitingIDs = []
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            flushHeld()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushHeld()
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
        // A click in the pane gives it the keys once the back shows. Before
        // that the keys are the answer field's, and a click into it must not
        // pull them away.
        .simultaneousGesture(TapGesture().onEnded { if openCard != nil { focused = true } })
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
            if !held.isEmpty {
                backButton
                    .padding(.top, 6)
            }
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
        }
    }

    /// Over the card: its source, which opens it, its place in what waits,
    /// the ⋯ for its source, and the strip of the cards gone through. A card
    /// that stands on several sources shows them together and opens any.
    private func header(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                sourceChip(card)
                Spacer(minLength: 12)
                if canGoBack { backButton }
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

    /// The sources the card will be kept on: its own, then the others it
    /// stands on that the learner has not taken off.
    private func keptSourceIDs(_ card: MemoryCardToCheck) -> [String] {
        let dropped = droppedSources[card.cardID] ?? []
        return card.sourceIDs.enumerated().filter { $0.offset == 0 || !dropped.contains($0.element) }.map(\.element)
    }

    /// The card's source as a chip: one source opens it; several show their
    /// pictures stacked and the count beyond the first, and open a popover
    /// listing them, each of which opens, and each other one of which can be
    /// taken off the card.
    @ViewBuilder
    private func sourceChip(_ card: MemoryCardToCheck) -> some View {
        let ids = keptSourceIDs(card)
        let title = sourceTitle(card.sourceID)
        if ids.count <= 1 && card.sourceIDs.count <= 1 {
            Button {
                openSource(card.sourceID)
            } label: {
                chipLabel(ids: ids, title: title, more: 0)
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: -5))
            .help("Open \(title)")
            .contextMenu { sourceMenu(card.sourceID) }
            .accessibilityLabel("Source: \(title)")
            .accessibilityIdentifier("memory.pane.toCheck.source")
        } else {
            Button {
                isListingSources.toggle()
            } label: {
                chipLabel(ids: ids, title: title, more: ids.count - 1)
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: -5))
            .popover(isPresented: $isListingSources, arrowEdge: .bottom) {
                sourcesPopover(card)
            }
            .onChange(of: card.cardID) { _, _ in isListingSources = false }
            .help("The sources this card stands on")
            .accessibilityLabel("Sources: \(ids.map(sourceTitle).joined(separator: ", "))")
            .accessibilityIdentifier("memory.pane.toCheck.source")
        }
    }

    /// The sources a card stands on, one row each: its picture and title, a
    /// click opens it, and each source after the card's own can be taken off
    /// the card or put back.
    private func sourcesPopover(_ card: MemoryCardToCheck) -> some View {
        let kept = Set(keptSourceIDs(card))
        return VStack(alignment: .leading, spacing: 2) {
            Text("This card stands on \(card.sourceIDs.count) sources")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
            ForEach(card.sourceIDs, id: \.self) { id in
                let isKept = kept.contains(id)
                let isOwn = id == card.sourceID
                HStack(spacing: 4) {
                    Button {
                        openSource(id)
                    } label: {
                        HStack(spacing: 10) {
                            sourceThumbnail(vm.articlesById[vm.canonicalSourceID(id)], size: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .opacity(isKept ? 1 : 0.45)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sourceTitle(id))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(isKept ? .primary : .secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .strikethrough(!isKept)
                                if let detail = sourceDetail(id) {
                                    Text(detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                if isOwn || !isKept {
                                    Text(isOwn ? "The card's own source" : "Taken off this card")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
                    .help("Open \(sourceTitle(id))")
                    .contextMenu { sourceMenu(id) }
                    .accessibilityLabel("Open source: \(sourceTitle(id))")
                    if !isOwn {
                        Button {
                            toggleDropped(id, on: card)
                        } label: {
                            Image(systemName: isKept ? "xmark" : "arrow.uturn.backward")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
                        .help(isKept ? "Take this source off the card" : "Use this source for the card")
                        .accessibilityLabel(isKept ? "Take off this card: \(sourceTitle(id))" : "Use for the card: \(sourceTitle(id))")
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 380)
        .accessibilityIdentifier("memory.pane.toCheck.sources")
    }

    private func chipLabel(ids: [String], title: String, more: Int) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: -8) {
                ForEach(Array(ids.prefix(3).enumerated()), id: \.element) { index, id in
                    sourceThumbnail(vm.articlesById[vm.canonicalSourceID(id)])
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .zIndex(Double(-index))
                }
            }
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .textSelection(.disabled)
            }
        }
        .contentShape(Rectangle())
    }

    private func toggleDropped(_ sourceID: String, on card: MemoryCardToCheck) {
        var dropped = droppedSources[card.cardID] ?? []
        if !dropped.insert(sourceID).inserted { dropped.remove(sourceID) }
        droppedSources[card.cardID] = dropped.isEmpty ? nil : dropped
    }

    /// The rest of the card's source at once, and the source's own menu.
    private func sourceActionsMenu(_ card: MemoryCardToCheck) -> some View {
        let rest = visible.filter { $0.sourceID == card.sourceID }
        let count = rest.count == 1 ? "1 card" : "\(rest.count) cards"
        return Menu {
            Section("\(count) from this source") {
                Button("Keep All") { decideAll(rest, keep: true) }
                Button("Skip All") { decideAll(rest, keep: false) }
            }
            Divider()
            drawPictureButton(card)
            Button("Copy Card ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.cardID, forType: .string)
            }
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
        .help("Keep or skip the rest of this source's cards, draw this card a picture, or copy its ID")
        .accessibilityLabel("More")
        .accessibilityIdentifier("memory.pane.toCheck.more")
    }

    /// The source's picture as every source list draws it: its cover, first
    /// page or artwork, else its kind's symbol; a book chapter the book's.
    @ViewBuilder
    private func sourceThumbnail(_ article: StudioArticle?, size: CGFloat = 24) -> some View {
        if let article {
            let bookCoverPath = article.sourceType == .book
                ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                : nil
            SourceThumbnail(source: article, size: size, bookCoverPath: bookCoverPath)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
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
                opened: opened(card).map { MemoryCardToCheckFace.Opened(attempt: $0.attempt, check: checks[card.cardID]) },
                attempt: $attemptDraft,
                autoFocusAttempt: windowState?.memoryPaneFocusCardID == nil,
                submit: { reveal(card) },
                passages: passages(of: card)
            )
            .id(card.cardID)
            .transition(.memoryCard(leavingTo: exitEdge, reduceMotion: reduceMotion))
            .contextMenu {
                if opened(card) != nil { Button("Keep") { decide(card, .keep) } }
                Button("Edit…") { editing = card }
                Button("Skip") { decide(card, .skip) }
                Divider()
                drawPictureButton(card)
                sourceMenu(card.sourceID)
                Divider()
                Button("Remove Source", role: .destructive) { removeSource(of: card) }
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

    /// Before the answer: I Don't Know and Check, as Review's, with Skip,
    /// Edit and Remove Source quiet under them. After it: Skip and Edit,
    /// pale; Keep, the dark pill that moves on; Remove Source quiet below.
    @ViewBuilder
    private func actions(_ card: MemoryCardToCheck) -> some View {
        let keys = focused && editing == nil
        if opened(card) != nil {
            VStack(spacing: 12) {
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
                HStack(spacing: 6) {
                    askInChatButton
                    removeSourceButton(card)
                }
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
                    askInChatButton
                    removeSourceButton(card)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// A follow-up on the card in front: a new chat opens beside the pane and
    /// reads the card as the chip over its composer shows it
    /// (`memoryCardOnScreen`), so "why is this wrong?" needs no pasting
    /// (product owner, 2026-10-16: "there has to be a better way to chat with
    /// flashcards to follow up; maybe give a direct button").
    private var askInChatButton: some View {
        MemoryReviewButton(title: "Ask in Chat", kind: .quiet) {
            if let windowState {
                vm.inWindow(windowState) { vm.requestChatAboutCardOnScreen() }
            } else {
                vm.requestChatAboutCardOnScreen()
            }
        }
        .help("Open a chat beside this card to follow up on it")
        .accessibilityIdentifier("memory.pane.toCheck.askInChat")
    }

    /// Not worth keeping, decided from the card: the source leaves the
    /// library as the Sources list's Remove does, with Undo, and every card
    /// of its waiting here is skipped (product owner, 2026-10-16: "there
    /// should be a button to remove certain sources").
    private func removeSourceButton(_ card: MemoryCardToCheck) -> some View {
        MemoryReviewButton(title: "Remove Source", kind: .quiet) { removeSource(of: card) }
            .help("Not worth keeping: remove this source from the library, with Undo, and skip its cards")
            .accessibilityIdentifier("memory.pane.toCheck.removeSource")
    }

    private func removeSource(of card: MemoryCardToCheck) {
        let sourceID = card.sourceID
        let theirs = visible.filter { $0.sourceID == sourceID }
        exitEdge = .leading
        decide(theirs.map { MemoryCardTriageDecision(card: $0, action: .skip) }, removing: sourceID)
        Task { await vm.removeArticle(id: sourceID) }
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
        if let attempt { startAnswerCheck(card, attempt: attempt) }
    }

    /// Sends the answer to the Card Answer Check, as Review does, off the
    /// main actor; the verdict lands under the fold while the card is still
    /// in front. A model that is not set up, or a failed call, says so on
    /// the card; nothing is graded by the app itself.
    private func startAnswerCheck(_ card: MemoryCardToCheck, attempt: String) {
        let cardID = card.cardID
        let step = vm.memoryCardAnswerCheck()
        let request = MemoryCardAnswerCheck.Request(
            front: card.face.front,
            back: card.face.back,
            why: card.face.why,
            quote: card.quote,
            answer: attempt
        )
        let title = sourceTitle(card.sourceID)
        checks[cardID] = .checking
        checkWork?.cancel()
        checkWork = Task {
            let outcome: MemoryCardSitting.AnswerCheck
            do {
                outcome = .judged(try await step(request, cardID, title == Self.missingSourceTitle ? nil : title))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                outcome = .failed(MemoryCardAnswerCheck.failureLine(error.localizedDescription))
            }
            guard !Task.isCancelled, checks[cardID] == .checking else { return }
            checks[cardID] = outcome
        }
    }

    @ViewBuilder
    private func sourceMenu(_ sourceID: String) -> some View {
        Button("Open Source") { openSource(sourceID) }
        OtherWindowSourceMenuItem(sourceID: sourceID)
    }

    /// The passages a card stands on, one for each source it will be kept on
    /// that it quotes, its own source's first.
    private func passages(of card: MemoryCardToCheck) -> [MemoryCardToCheckFace.Passage] {
        let kept = Set(keptSourceIDs(card))
        return card.links.filter { kept.contains($0.sourceID) }.map { link in
            MemoryCardToCheckFace.Passage(
                id: "\(link.sourceID)#\(link.quote.hashValue)",
                sourceTitle: sourceTitle(link.sourceID),
                open: { openSource(link.sourceID, passage: link.quote) }
            )
        }
    }

    /// The Reader beside the pane, at the passage a card quotes when it
    /// names one.
    private func openSource(_ sourceID: String, passage: String? = nil) {
        Task { await vm.openLinkedSourceInReader(sourceID, passage: passage, beside: .memory) }
    }

    // MARK: Going back

    /// Back has something to take back: the answer of the card in front, else
    /// the last decision, while it is still unwritten.
    private var canGoBack: Bool {
        if let card = current, opened(card) != nil { return true }
        return !held.isEmpty
    }

    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6, inset: 0)
        .help(current.flatMap(opened) != nil
            ? "Back to the question"
            : "Take the last decision back and bring its card here again")
        .accessibilityIdentifier("memory.pane.toCheck.back")
    }

    /// A card turned over goes back to its question, with what was written
    /// for it; otherwise the newest decision still unwritten is taken back and
    /// its card is dealt in front again, unanswered.
    private func goBack() {
        if let card = current, let shown = opened(card) {
            checkWork?.cancel()
            checks[card.cardID] = nil
            attemptDraft = shown.attempt ?? ""
            withAnimation(.easeOut(duration: 0.22)) { openCard = nil }
            return
        }
        guard let last = held.last else { return }
        guard let sourceID = last.removedSourceID else {
            restore(last)
            return
        }
        Task {
            guard await vm.undoPendingDeletion(forSourceID: sourceID) else {
                vm.showToast("That source is already removed, so its cards stay skipped.")
                return
            }
            restore(last)
        }
    }

    private func restore(_ entry: Held) {
        guard held.contains(where: { $0.id == entry.id }) else { return }
        held.removeAll { $0.id == entry.id }
        if held.isEmpty {
            flushWork?.cancel()
            flushWork = nil
        }
        let ids = entry.decisions.map(\.card.cardID)
        exitEdge = .trailing
        withAnimation(Self.dealAnimation) {
            decided.subtract(ids)
            gone.removeAll { ids.contains($0.cardID) }
            selection = ids.first
        }
    }

    /// Writes every decision still held, once.
    private func flushHeld() {
        flushWork?.cancel()
        flushWork = nil
        let batch = held.flatMap(\.decisions)
        held = []
        guard !batch.isEmpty else { return }
        let ids = Set(batch.map(\.card.cardID))
        Task {
            let result = await vm.triageCardsToCheck(batch)
            let failed = Set(result.failed.map(\.cardID))
            // What was held for a decided card goes with it; a card storage
            // refused comes back with its pictures.
            for id in ids.subtracting(failed) { windowState?.memoryCardPictures[id] = nil }
            guard !failed.isEmpty else { return }
            decided.subtract(failed)
            gone.removeAll { failed.contains($0.cardID) }
        }
    }

    // MARK: Drawing a picture

    /// The ••• and right-click item that draws the card a picture: one image
    /// request on Settings › Images' model, only when chosen. The picture sits
    /// with the answer and is kept with the card when it is kept.
    @ViewBuilder
    private func drawPictureButton(_ card: MemoryCardToCheck) -> some View {
        let isDrawing = drawing.contains(card.cardID)
        let hasDrawn = drawn[card.cardID] != nil
        Button(isDrawing ? "Drawing Picture…" : hasDrawn ? "Draw Picture Again" : "Draw Picture") {
            drawPicture(for: card)
        }
        .disabled(isDrawing || (!hasDrawn && card.face.backImages.count >= MemoryCard.maximumImagesPerFace))
    }

    private func drawPicture(for card: MemoryCardToCheck) {
        let cardID = card.cardID
        guard drawing.insert(cardID).inserted else { return }
        let title = sourceTitle(card.sourceID)
        Task {
            defer { drawing.remove(cardID) }
            do {
                drawn[cardID] = try await CardPictureDrawer.draw(
                    card,
                    sourceTitle: title == Self.missingSourceTitle ? nil : title,
                    passage: card.quote,
                    model: MacImageGenerationSettings.model
                )
            } catch {
                drawFailure = error.localizedDescription
            }
        }
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
    /// holds the decisions for Back before writing them (`flushHeld`); a card
    /// storage refused comes back.
    private func decide(_ given: [MemoryCardTriageDecision], removing removedSourceID: String? = nil) {
        guard !given.isEmpty else { return }
        let decisions = given.map(withSourcesTakenOff)
        focused = true
        let ids = Set(decisions.map(\.card.cardID))
        for id in ids { checks[id] = nil }
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
        held.append(Held(decisions: decisions, removedSourceID: removedSourceID))
        flushWork?.cancel()
        flushWork = Task {
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            flushHeld()
        }
    }

    /// A decision that keeps a draft, kept on the sources the learner left it
    /// on: unchanged when they took none off.
    private func withSourcesTakenOff(_ decision: MemoryCardTriageDecision) -> MemoryCardTriageDecision {
        let card = decision.card
        guard let dropped = droppedSources[card.cardID], !dropped.isEmpty else { return decision }
        let kept = Set(keptSourceIDs(card))
        let remaining = card.alsoFrom.filter { kept.contains($0.sourceID) }
        switch decision.action {
        case .skip:
            return decision
        case .keep:
            let face = card.face
            let edit = MemoryCardEdit(
                front: face.front, back: face.back, why: face.why,
                frontImages: face.frontImages, backImages: face.backImages
            ).keptOn(remaining)
            return MemoryCardTriageDecision(card: card, action: .keepEdited(edit))
        case .keepEdited(let edit):
            return MemoryCardTriageDecision(card: card, action: .keepEdited(edit.keptOn(remaining)))
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
        guard editing == nil, let card = current, opened(card) != nil else { return false }
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

    /// The card in front as a chat is told of it: the question, the back and
    /// why, its source, its place, and whether the learner has turned it over.
    private var onScreenCard: ChatContextAdditions.CardOnScreen? {
        guard let card = current else { return nil }
        let canonical = vm.canonicalSourceID(card.sourceID)
        let title = vm.articlesById[canonical]?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatContextAdditions.CardOnScreen(
            id: card.cardID,
            question: card.face.front,
            answer: card.face.back,
            why: card.face.why,
            sourceID: canonical,
            sourceTitle: title?.isEmpty == false ? title : nil,
            place: "\(MemoryPaneSection.toCheck.title), \(gone.count + 1) of \(gone.count + visible.count)",
            answerShown: opened(card) != nil,
            frontImages: card.face.frontImages.map(\.markdown),
            backImages: card.face.backImages.map(\.markdown)
        )
    }

    /// A line under a source's title: a paper's authors, venue and year, else
    /// the group it sits in or its site.
    private func sourceDetail(_ sourceID: String) -> String? {
        guard let article = vm.articlesById[vm.canonicalSourceID(sourceID)] else { return nil }
        var parts: [String] = []
        if article.sourceType == .paper {
            parts = article.paperMetadataDisplayParts.filter {
                $0 != StudioArticle.unknownPaperAuthor
                    && $0 != StudioArticle.unknownPaperJournal
                    && $0 != StudioArticle.unknownPaperYear
            }
        }
        if parts.isEmpty {
            if let context = vm.sourceGroupTitle(for: article), !context.isEmpty {
                parts.append(context)
            } else if let domain = article.displayDomain {
                parts.append(domain)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceTitle(_ sourceID: String) -> String {
        let title = vm.articlesById[vm.canonicalSourceID(sourceID)]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? Self.missingSourceTitle : title
    }

    private static let missingSourceTitle = "Source not in the library"
}

// MARK: - A card to check

/// One card to check, drawn as Review draws a card: the deck's paper, the
/// front in the review's serif and its pictures. Until the learner answers,
/// the field for the answer is all that is under the front; once they have (or said they do
/// not know), the learner's answer, the fold, the back, why it holds and
/// Show Passage follow.
private struct MemoryCardToCheckFace: View {
    /// A card whose back is showing, and the answer that opened it (nil when
    /// the learner said they did not know).
    struct Opened: Equatable {
        let attempt: String?
        /// Where the check of that answer stands; nil for "I Don't Know".
        let check: MemoryCardSitting.AnswerCheck?
    }

    let card: MemoryCardToCheck
    /// Nil while the card waits for an answer.
    let opened: Opened?
    @Binding var attempt: String
    /// Whether the answer field takes the keys when the card is dealt: not
    /// when a chat opened the pane at this card and keeps its composer.
    let autoFocusAttempt: Bool
    /// Return in the answer field.
    let submit: () -> Void
    /// Where the card stands on each of its sources, each opening its source
    /// at the passage; empty when it quotes none.
    let passages: [Passage]

    struct Passage: Identifiable {
        let id: String
        let sourceTitle: String
        let open: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.face.front.foldingMathSpans())
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
    /// Shift-Return starts a new line, and the mic dictates into it.
    private var attemptField: some View {
        MemoryCardAttemptBox(
            text: $attempt,
            onSubmit: submit,
            autoFocus: autoFocusAttempt,
            identifier: "memory.pane.toCheck.attempt"
        )
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

    /// Under the fold: the verdict on the learner's answer when one was
    /// given, then the back, its pictures, why it holds, Show Passage.
    private var answerFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryCardFold()
                .padding(.vertical, 22)
            if let check = opened?.check {
                MemoryCardVerdictLine(check: check)
                    .padding(.bottom, 16)
            }
            Text(card.face.back.foldingMathSpans())
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
            if let first = passages.first {
                if passages.count == 1 {
                    Button(action: first.open) {
                        Label("Show Passage", systemImage: "text.quote")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, tint: .secondary))
                    .help("Open the source at the passage this card stands on")
                    .accessibilityIdentifier("memory.pane.toCheck.passage")
                    .padding(.top, 20)
                } else {
                    Menu {
                        ForEach(passages) { passage in
                            Button(passage.sourceTitle, action: passage.open)
                        }
                    } label: {
                        Label("Show Passage", systemImage: "text.quote")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHighlight(cornerRadius: 6, inset: -4)
                    .help("Open a source at the passage this card stands on")
                    .accessibilityIdentifier("memory.pane.toCheck.passage")
                    .padding(.top, 20)
                }
            }
        }
    }
}

// MARK: - Editing a card to check

/// A card to check's front, back and why, kept in the learner's words: Keep
/// keeps the edited card.
struct MemoryCardToCheckEditorSheet: View {
    let card: MemoryCardToCheck
    let keep: (MemoryCardEdit) -> Void
    let cancel: () -> Void

    @State private var front: String
    @State private var back: String
    @State private var why: String

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

    var body: some View {
        MemoryCardEditorForm(
            front: $front,
            back: $back,
            why: $why,
            frontImages: card.face.frontImages,
            backImages: card.face.backImages,
            primaryTitle: "Keep",
            canSave: !edit.front.isEmpty && !edit.back.isEmpty,
            cancel: cancel
        ) {
            keep(edit)
        }
        .accessibilityIdentifier("memory.pane.toCheck.editor")
    }
}
