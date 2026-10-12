import SwiftUI

/// The Memory pane's **To Check** (docs/memory-design.md, "Cards to check"):
/// the cards drafted from sources and not yet gone through, and the items from
/// before cards, offered once — a source at a time, the scope the pane's
/// (every notebook, or one: a notebook's Studio Cards row opens it narrowed to
/// the notebook, in the notebook's document slot).
///
/// The layout (design-mockups/memory-cards-to-check.svg): a centred column;
/// each source headed by its cover and title, which open it; each card drawn
/// as the card it would be — its front in the card review's serif, a rule,
/// its back, why — with its own actions under it.
///
/// - A card drafted unasked, or one from before cards: **Keep** makes it a
///   card of Memory (`keepMemoryCard`), **Edit** keeps it in the learner's
///   words, **Skip** drops it for good; with the list focused, K, E and S do
///   the same to the selected card, and ↑ ↓ move the selection.
/// - A card the learner asked for arrives ticked, and its tick is its
///   decision: K ticks it, S unticks it (Space toggles), E edits it. The bar
///   pinned to the bottom counts the ticks and its **Keep N Cards** keeps the
///   ticked ones and drops the unticked.
/// - A source: **Keep All** and **Skip All** (Skip All asks first when it
///   would retire cards from before).
///
/// Nothing is written until the learner decides; a decided card leaves the
/// list at once and comes back only if storage refused it. A draft is offered
/// for 14 days after it was drafted, which is computed on reading, never
/// written. The list claims keys only while it has focus: inside a notebook it
/// sits beside the chat, whose typing is the composer's. The rows are lazy, so
/// a card builds its buttons only while it is on screen (an assistive app pays
/// every control an update builds against every control the window holds).
struct MemoryCardsToCheckView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// The pane's read of the scope's cards to check, in their order.
    let cards: [MemoryCardToCheck]
    let hasLoaded: Bool

    /// Requested drafts the learner unticked: dropped by Keep N Cards.
    @State private var unticked: Set<String> = []
    /// Cards decided and on their way to storage, hidden meanwhile.
    @State private var decided: Set<String> = []
    @State private var selection: String?
    @State private var editing: MemoryCardToCheck?
    @State private var confirmingSkipAll: MemoryCardTriage.Group?
    @FocusState private var listFocused: Bool

    /// The column the list reads in, centred in a wide pane.
    private static let columnMaxWidth: CGFloat = 680

    private var visible: [MemoryCardToCheck] { cards.filter { !decided.contains($0.cardID) } }

    /// The requested drafts on screen, ticked or not: what Keep N Cards decides.
    private var requested: [MemoryCardToCheck] {
        visible.filter { $0.kind == .draft && $0.isRequested }
    }

    var body: some View {
        let visible = visible
        let groups = MemoryCardTriage.grouped(visible)
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                list(visible, groups: groups)
            }
        }
        .onChange(of: cards.map(\.cardID)) { _, ids in
            // A fresh read: what storage refused is back, what it wrote is gone.
            let present = Set(ids)
            decided.formIntersection(present)
            unticked.formIntersection(present)
            if let selection, !present.contains(selection) { self.selection = nil }
            takeFocusCard()
        }
        .onAppear { takeFocusCard() }
        .onChange(of: windowState?.memoryPaneFocusCardID) { _, _ in takeFocusCard() }
        .sheet(item: $editing) { card in
            MemoryCardToCheckEditorSheet(card: card) { edit in
                editing = nil
                decide([MemoryCardTriageDecision(card: card, action: .keepEdited(edit))])
            } cancel: {
                editing = nil
            }
        }
        .alert(
            "Skip every card from this source?",
            isPresented: Binding(
                get: { confirmingSkipAll != nil },
                set: { if !$0 { confirmingSkipAll = nil } }
            ),
            presenting: confirmingSkipAll
        ) { group in
            Button("Skip All", role: .destructive) {
                decide(group.cards.map { MemoryCardTriageDecision(card: $0, action: .skip) })
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cards from before cards are retired and never asked again.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.pane.toCheck")
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

    // MARK: The list

    /// The list a row at a time — a source's header, then its cards — flat,
    /// so the lazy stack builds each card on its own.
    private enum Row: Identifiable {
        case source(MemoryCardTriage.Group, isFirst: Bool)
        case card(MemoryCardToCheck)

        /// A card's row is its card id, which the selection scrolls to.
        var id: String {
            switch self {
            case .source(let group, _): return "source:" + group.sourceID
            case .card(let card): return card.cardID
            }
        }
    }

    private static func rows(_ groups: [MemoryCardTriage.Group]) -> [Row] {
        groups.enumerated().flatMap { index, group in
            [Row.source(group, isFirst: index == 0)] + group.cards.map { Row.card($0) }
        }
    }

    private func list(_ visible: [MemoryCardToCheck], groups: [MemoryCardTriage.Group]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(MemoryCardTriage.summary(visible) ?? "Nothing to check")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .textSelection(.disabled)
                        .padding(.bottom, 18)
                        .accessibilityIdentifier("memory.pane.toCheck.summary")
                    ForEach(Self.rows(groups)) { row in
                        switch row {
                        case .source(let group, let isFirst):
                            sourceHeader(group)
                                .padding(.top, isFirst ? 0 : 20)
                                .padding(.bottom, 10)
                        case .card(let card):
                            cardRow(card)
                                .padding(.bottom, 10)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !requested.isEmpty { keepBar }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(characters: CharacterSet(charactersIn: "kesKES"), phases: .down) { press in
                handleKey(press.characters.lowercased()) ? .handled : .ignored
            }
            .onKeyPress(.upArrow) { moveSelection(by: -1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { moveSelection(by: 1) ? .handled : .ignored }
            .onKeyPress(.space) { toggleSelectedTick() ? .handled : .ignored }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    // MARK: The bar

    /// Pinned to the bottom while cards the learner asked for wait: how many
    /// are ticked, and the one button that keeps them and drops the rest.
    private var keepBar: some View {
        let requested = requested
        let ticked = requested.filter { !unticked.contains($0.cardID) }.count
        let left = requested.count - ticked
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                // "3 of 4 ticked" over Keep 3 Cards, the unticked card faded,
                // says what the button keeps; the caption that said the
                // unticked are skipped went on 2026-10-06 (the button's help
                // still says it).
                Text("\(ticked) of \(requested.count) ticked")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .textSelection(.disabled)
                Spacer(minLength: 12)
                // No Return: inside a notebook the pane sits beside the chat.
                // The review's dark pill, never a blue one (docs/ui-design.md).
                if ticked > 0 {
                    MemoryReviewButton(title: ticked == 1 ? "Keep 1 Card" : "Keep \(ticked) Cards", kind: .primary, minWidth: 140) {
                        decide(MemoryCardTriage.keepRequested(visible, unticked: unticked))
                    }
                    .help("Keep the ticked cards, and skip the rest you asked for")
                    .accessibilityIdentifier("memory.pane.toCheck.keepRequested")
                } else {
                    MemoryReviewButton(title: left == 1 ? "Skip 1 Card" : "Skip \(left) Cards", kind: .secondary, minWidth: 140) {
                        decide(MemoryCardTriage.keepRequested(visible, unticked: unticked))
                    }
                    .help("Skip every card you asked for: none is ticked")
                    .accessibilityIdentifier("memory.pane.toCheck.keepRequested")
                }
            }
            .frame(maxWidth: Self.columnMaxWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
    }

    // MARK: A source

    private func sourceHeader(_ group: MemoryCardTriage.Group) -> some View {
        let title = sourceTitle(group.sourceID)
        let article = vm.articlesById[vm.canonicalSourceID(group.sourceID)]
        return HStack(alignment: .center, spacing: 12) {
            Button {
                openSource(group.sourceID)
            } label: {
                HStack(spacing: 10) {
                    sourceThumbnail(article)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(Self.groupDetail(group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: -5))
            .help("Open \(title)")
            .contextMenu { sourceMenu(group.sourceID) }
            .accessibilityIdentifier("memory.pane.toCheck.source.\(group.sourceID)")
            Spacer(minLength: 12)
            Button("Keep All") {
                decide(MemoryCardTriage.keepAll(group.cards, unticked: unticked))
            }
            .font(.callout)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, tint: .accentColor))
            .help("Keep every card from this source")
            .accessibilityIdentifier("memory.pane.toCheck.keepAll.\(group.sourceID)")
            Button("Skip All") {
                if group.cards.contains(where: { $0.kind == .legacy }) {
                    confirmingSkipAll = group
                } else {
                    decide(group.cards.map { MemoryCardTriageDecision(card: $0, action: .skip) })
                }
            }
            .font(.callout)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, tint: .secondary))
            .help("Skip every card from this source")
            .accessibilityIdentifier("memory.pane.toCheck.skipAll.\(group.sourceID)")
        }
        .textSelection(.disabled)
    }

    /// The source's picture as every source list draws it: its cover, first
    /// page or artwork, else its kind's symbol; a book chapter the book's.
    @ViewBuilder
    private func sourceThumbnail(_ article: StudioArticle?) -> some View {
        if let article {
            let bookCoverPath = article.sourceType == .book
                ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                : nil
            SourceThumbnail(source: article, size: 34, bookCoverPath: bookCoverPath)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary))
                .accessibilityHidden(true)
        }
    }

    /// "4 cards · drafted today", by the group's newest draft; a source only
    /// items from before cards wait on says so instead.
    static func groupDetail(_ group: MemoryCardTriage.Group, now: Date = Date(), calendar: Calendar = .current) -> String {
        let count = group.cards.count == 1 ? "1 card" : "\(group.cards.count) cards"
        guard let drafted = group.cards.compactMap(\.draftedAt).max() else {
            return "\(count) from before cards"
        }
        let day: String
        if calendar.isDate(drafted, inSameDayAs: now) {
            day = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(drafted, inSameDayAs: yesterday) {
            day = "yesterday"
        } else {
            day = drafted.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(count) · drafted \(day)"
    }

    // MARK: A card

    private func cardRow(_ card: MemoryCardToCheck) -> some View {
        let isSelected = selection == card.cardID
        let isRequested = card.kind == .draft && card.isRequested
        return MemoryCardToCheckRow(
            card: card,
            tick: isRequested ? tickBinding(card) : nil,
            isSelected: isSelected,
            showsKeys: isSelected && listFocused,
            keep: { decide([MemoryCardTriageDecision(card: card, action: .keep)]) },
            edit: { editing = card },
            skip: { decide([MemoryCardTriageDecision(card: card, action: .skip)]) },
            showPassage: passage(of: card).map { quote in { openSource(card.sourceID, passage: quote) } }
        )
        .onTapGesture(count: 2) { editing = card }
        .onTapGesture {
            selection = card.cardID
            listFocused = true
        }
        .contextMenu {
            Button("Keep") { decide([MemoryCardTriageDecision(card: card, action: .keep)]) }
            Button("Edit…") { editing = card }
            Button("Skip") { decide([MemoryCardTriageDecision(card: card, action: .skip)]) }
            Divider()
            if let quote = passage(of: card) {
                Button("Show Passage") { openSource(card.sourceID, passage: quote) }
            }
            sourceMenu(card.sourceID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Keep") { decide([MemoryCardTriageDecision(card: card, action: .keep)]) }
        .accessibilityAction(named: "Edit") { editing = card }
        .accessibilityAction(named: "Skip") { decide([MemoryCardTriageDecision(card: card, action: .skip)]) }
        .accessibilityIdentifier("memory.pane.toCheck.card.\(card.cardID)")
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

    private func tickBinding(_ card: MemoryCardToCheck) -> Binding<Bool> {
        Binding(
            get: { !unticked.contains(card.cardID) },
            set: { ticked in setTick(card, ticked) }
        )
    }

    private func setTick(_ card: MemoryCardToCheck, _ ticked: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if ticked { unticked.remove(card.cardID) } else { unticked.insert(card.cardID) }
        }
    }

    // MARK: Deciding

    /// Hides the decided cards at once, moves the selection past them, and
    /// writes the decisions; a card storage refused comes back.
    private func decide(_ decisions: [MemoryCardTriageDecision]) {
        guard !decisions.isEmpty else { return }
        let ids = Set(decisions.map(\.card.cardID))
        if let selection, ids.contains(selection) {
            let remaining = visible.map(\.cardID)
            let after = remaining.drop { $0 != selection }.dropFirst().first { !ids.contains($0) }
            let before = remaining.prefix { $0 != selection }.last { !ids.contains($0) }
            self.selection = after ?? before
        }
        withAnimation(.easeOut(duration: 0.18)) { decided.formUnion(ids) }
        Task {
            let result = await vm.triageCardsToCheck(decisions)
            decided.subtract(result.failed.map(\.cardID))
        }
    }

    /// The card a chat's saved cards were opened at
    /// (`StudioWindowState.memoryPaneFocusCardID`): selected, which scrolls
    /// to it. The list keeps the keys it had: the chat beside it keeps its
    /// composer.
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

    private var selectedCard: MemoryCardToCheck? {
        guard let selection else { return nil }
        return visible.first { $0.cardID == selection }
    }

    /// K, E and S on the selected card. A card the learner asked for is
    /// decided by its tick, so K ticks it and S unticks it, and the
    /// selection moves on; any other card is kept or skipped there and then.
    private func handleKey(_ key: String) -> Bool {
        guard let card = selectedCard else { return false }
        let isRequested = card.kind == .draft && card.isRequested
        switch key {
        case "k":
            if isRequested {
                setTick(card, true)
                _ = moveSelection(by: 1)
            } else {
                decide([MemoryCardTriageDecision(card: card, action: .keep)])
            }
        case "e":
            editing = card
        case "s":
            if isRequested {
                setTick(card, false)
                _ = moveSelection(by: 1)
            } else {
                decide([MemoryCardTriageDecision(card: card, action: .skip)])
            }
        default:
            return false
        }
        return true
    }

    private func moveSelection(by step: Int) -> Bool {
        let ids = visible.map(\.cardID)
        guard !ids.isEmpty else { return false }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            self.selection = step > 0 ? ids.first : ids.last
            return true
        }
        let next = index + step
        guard ids.indices.contains(next) else { return false }
        self.selection = ids[next]
        return true
    }

    private func toggleSelectedTick() -> Bool {
        guard let card = selectedCard, card.kind == .draft, card.isRequested else { return false }
        setTick(card, unticked.contains(card.cardID))
        return true
    }

    private func sourceTitle(_ sourceID: String) -> String {
        let title = vm.articlesById[vm.canonicalSourceID(sourceID)]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Source not in the library" : title
    }
}

// MARK: - A card to check

/// One card to check, drawn as the card it would be: its difficulty, the
/// front in the card review's serif, its pictures, the fold, the back, and why
/// it is right; under it, Show Passage and its actions. A card the learner
/// asked for carries its tick at the leading edge and only Edit, since the
/// tick is its keep or skip; unticked, the card fades. While the list has
/// focus the selected card's buttons show their keys.
private struct MemoryCardToCheckRow: View {
    let card: MemoryCardToCheck
    /// The card's tick, for a card the learner asked for; nil otherwise.
    let tick: Binding<Bool>?
    let isSelected: Bool
    let showsKeys: Bool
    let keep: () -> Void
    let edit: () -> Void
    let skip: () -> Void
    /// Opens the source at the passage the card quotes; nil when it quotes none.
    let showPassage: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private static let cornerRadius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let isLeftOut = tick?.wrappedValue == false
        HStack(alignment: .top, spacing: 12) {
            if let tick {
                tickButton(tick)
            }
            VStack(alignment: .leading, spacing: 0) {
                face
                    .opacity(isLeftOut ? 0.45 : 1)
                actions
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                // In dark mode the control colour is the pane's own; a touch
                // of white lifts the card off it.
                .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0)))
                .shadow(color: .black.opacity(isHovered || isSelected ? 0.08 : 0.04), radius: isHovered ? 8 : 4, y: 2)
        )
        .overlay(shape.strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 0.5))
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor.opacity(showsKeys ? 0.75 : 0.4) }
        return Color.primary.opacity(isHovered ? 0.18 : 0.1)
    }

    // MARK: The face

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            if card.face.difficulty != nil || card.kind == .legacy {
                MemoryCardTagLine(tags: [card.face.difficulty?.rawValue, card.kind == .legacy ? "From before cards" : nil].compactMap { $0 })
                    .padding(.bottom, 10)
            }
            Text(card.face.front)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.face.frontImages)
                    .padding(.top, 10)
            }
            MemoryCardFold()
                .padding(.vertical, 12)
            Text(card.face.back)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.backImages.isEmpty {
                MemoryCardImageGrid(images: card.face.backImages)
                    .padding(.top, 10)
            }
            if !card.face.why.isEmpty {
                MemoryCardWhyLine(why: card.face.why)
                    .padding(.top, 10)
            }
        }
        .textSelection(.disabled)
    }

    // MARK: The actions

    private func tickButton(_ tick: Binding<Bool>) -> some View {
        Button {
            tick.wrappedValue.toggle()
        } label: {
            Image(systemName: tick.wrappedValue ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(tick.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tick.wrappedValue
              ? "Ticked: Keep Cards keeps it. Untick it to skip it (S, or Space)"
              : "Unticked: Keep Cards skips it. Tick it to keep it (K, or Space)")
        .accessibilityLabel("Keep this card")
        .accessibilityValue(tick.wrappedValue ? "Ticked" : "Unticked")
        .accessibilityAddTraits(.isToggle)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let showPassage {
                Button(action: showPassage) {
                    Label("Show Passage", systemImage: "text.quote")
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, tint: .secondary))
                .help("Open the source at the passage this card stands on")
                .accessibilityIdentifier("memory.pane.toCheck.passage.\(card.cardID)")
            }
            Spacer(minLength: 8)
            if tick == nil {
                actionButton("Skip", systemImage: "xmark", key: "S", tint: .secondary, run: skip)
                    .accessibilityIdentifier("memory.pane.toCheck.skip.\(card.cardID)")
            }
            actionButton("Edit", systemImage: "pencil", key: "E", tint: .secondary, run: edit)
                .accessibilityIdentifier("memory.pane.toCheck.edit.\(card.cardID)")
            if tick == nil {
                Button(action: keep) {
                    actionLabel("Keep", systemImage: "checkmark", key: "K")
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.1, tint: .accentColor))
                .help("Keep (K)")
                .accessibilityIdentifier("memory.pane.toCheck.keep.\(card.cardID)")
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
    }

    private func actionButton(_ title: String, systemImage: String, key: String, tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            actionLabel(title, systemImage: systemImage, key: key)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3, tint: tint))
        .help("\(title) (\(key))")
    }

    private func actionLabel(_ title: String, systemImage: String, key: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
            Text(title)
            if showsKeys {
                Text(key)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2))
                    )
                    .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Card")
                .font(.title3.weight(.semibold))
                .textSelection(.disabled)
            field("Front", text: $front)
            field("Back", text: $back)
            field("Why", text: $why)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Keep") {
                    if startsOver {
                        confirmingStartOver = true
                    } else {
                        keep(edit)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(edit.front.isEmpty || edit.back.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("Start this card over?", isPresented: $confirmingStartOver) {
            Button("Start Over") { keep(edit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new answer makes a new card, first asked tomorrow. Its answers so far stay with the old one.")
        }
        .accessibilityIdentifier("memory.pane.toCheck.editor")
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}
