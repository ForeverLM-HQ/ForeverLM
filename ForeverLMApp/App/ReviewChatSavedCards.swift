// The cards a chat saved, shown under the message that made them.

import SwiftUI

// MARK: - The cards a chat saved

/// The cards a chat saved (`save_card_drafts`), drawn in the reply as the cards
/// themselves (docs/memory-design.md, "The cards in the chat"). The reply
/// does not only say in prose what it saved, under a bare `save_card_drafts`
/// step (product owner, 2026-10-06: "it should immediately point to those
/// actual cards").
///
/// A small deck: the card on top drawn as To Check draws it — the front in
/// the card review's serif, a rule, the back — with where it
/// stands now, the cards under it stacked behind, ‹ › to page through them.
/// The header counts them as they stand ("6 cards to check", "4 to check · 2
/// kept"). Its one primary action, **Check Cards**, opens To Check beside the
/// chat at the card on top (`openChatSavedCard`); **Keep All** keeps every card
/// still to check, as the reply's own words promise one press does. A click on
/// a card to check opens To Check at it; its right-click keeps it or shows the
/// passage it stands on. What the cards stand at is read again whenever a card
/// is kept or skipped anywhere (`memoryCardRevision`).
struct ReviewChatSavedCardsView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.colorScheme) private var colorScheme

    let saved: ChatSavedCards
    /// Set when the deck is drawn in a popover: called once a card is opened in
    /// the Memory pane, so the popover closes as its cards move there.
    var onOpenedInMemory: (() -> Void)?

    /// The cards as storage read them, in the call's order; nil until read.
    @State private var cards: [ChatSavedCard]?
    @State private var readFailed = false
    @State private var page: Int
    @State private var isKeeping = false
    @State private var isHovered = false

    private static let maxWidth: CGFloat = 560

    /// Opened again, the deck shows the cards it last read, on the card it
    /// was left at (`ChatSavedCardsMemory`), while a fresh read lands.
    init(saved: ChatSavedCards) {
        self.saved = saved
        _cards = State(initialValue: ChatSavedCardsMemory.cards["\(saved.destination)"])
        _page = State(initialValue: ChatSavedCardsMemory.pages["\(saved.destination)"] ?? 0)
    }

    private var reloadKey: String { "\(saved.destination)#\(vm.memoryCardRevision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let cards, !cards.isEmpty {
                let shown = min(page, cards.count - 1)
                deck(cards, page: shown)
                if cards.contains(where: { $0.toCheck != nil }) {
                    footer(cards, page: shown)
                }
            } else if cards != nil || readFailed {
                Text(readFailed ? "These cards could not be read." : "These cards are not on this Mac right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
        // Inline, the deck sits in its own tinted box under the reply. In a
        // popover the popover is the box: no second one inside it, so the
        // header and card share one even margin and nothing runs past it.
        .padding(onOpenedInMemory == nil ? 14 : 0)
        .frame(maxWidth: onOpenedInMemory == nil ? Self.maxWidth : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
                .opacity(onOpenedInMemory == nil ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .opacity(onOpenedInMemory == nil ? 1 : 0)
        )
        .textSelection(.disabled)
        .task(id: reloadKey) { await load() }
        .onChange(of: page) { _, page in
            ChatSavedCardsMemory.pages["\(saved.destination)"] = page
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.savedCards")
    }

    // MARK: The header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(cards, saved: saved))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(saved.notSavedCount > 0
                              ? "A card whose quote the source does not print word for word is not saved."
                              : "")
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let cards, cards.count > 1 {
                pager(count: cards.count, page: min(page, cards.count - 1))
            }
            if onOpenedInMemory != nil, let cards, !cards.isEmpty {
                Button {
                    let shown = cards[min(page, cards.count - 1)]
                    open(shown.toCheck != nil ? shown : cards.first { $0.toCheck != nil } ?? shown)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, tint: .accentColor))
                .help("Move these cards into the Memory pane")
                .accessibilityLabel("Open in Memory")
                .accessibilityIdentifier("chat.savedCards.openInMemory")
            }
        }
    }

    /// "6 cards to check" while every card waits, "6 cards kept" once all are
    /// kept, else the cards and how they stand: "6 cards · 4 to check · 2
    /// kept". Before the first read, the words the reply was stored with.
    static func title(_ cards: [ChatSavedCard]?, saved: ChatSavedCards) -> String {
        guard let cards, !cards.isEmpty else { return saved.label }
        func plural(_ count: Int) -> String { count == 1 ? "1 card" : "\(count) cards" }
        var toCheck = 0, kept = 0, skipped = 0, notOffered = 0
        for card in cards {
            switch card.standing {
            case .toCheck: toCheck += 1
            case .kept: kept += 1
            case .skipped: skipped += 1
            case .notOffered: notOffered += 1
            }
        }
        let parts = [
            (toCheck, "to check"), (kept, "kept"), (skipped, "skipped"), (notOffered, "no longer offered"),
        ].filter { $0.0 > 0 }
        if parts.count == 1, let only = parts.first { return "\(plural(only.0)) \(only.1)" }
        return ([plural(cards.count)] + parts.map { "\($0.0) \($0.1)" }).joined(separator: " · ")
    }

    /// The source the cards stand on, and how many the call sent that were not
    /// saved.
    private var subtitle: String? {
        Self.subtitle(saved, articlesById: vm.articlesById, canonicalID: vm.canonicalSourceID)
    }

    static func subtitle(
        _ saved: ChatSavedCards,
        articlesById: [String: StudioArticle],
        canonicalID: (String) -> String
    ) -> String? {
        var parts: [String] = []
        if saved.sourceIDs.count == 1 {
            let title = articlesById[canonicalID(saved.sourceIDs[0])]?.title
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { parts.append(title) }
        } else if saved.sourceIDs.count > 1 {
            parts.append("From \(saved.sourceIDs.count) sources")
        }
        if saved.notSavedCount > 0 {
            parts.append("\(saved.notSavedCount) not saved")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pager(count: Int, page: Int) -> some View {
        HStack(spacing: 2) {
            pageButton("chevron.left", help: "Previous card", step: -1)
                .disabled(page == 0)
            Text("\(page + 1) of \(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
            pageButton("chevron.right", help: "Next card", step: 1)
                .disabled(page >= count - 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card \(page + 1) of \(count)")
    }

    private func pageButton(_ systemImage: String, help: String, step: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { page = max(0, page + step) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, tint: .secondary))
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: The deck

    private func deck(_ cards: [ChatSavedCard], page: Int) -> some View {
        let card = cards[page]
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // The cards still under this one, up to two, peek out below it.
        let under = min(2, cards.count - 1 - page)
        let opensToCheck = card.toCheck != nil
        return face(card)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill(shape))
            .overlay(shape.strokeBorder(Color.primary.opacity(isHovered && opensToCheck ? 0.2 : 0.1), lineWidth: 0.5))
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    ForEach(Array((0..<under).reversed()), id: \.self) { depth in
                        cardFill(shape)
                            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            .padding(.horizontal, CGFloat(depth + 1) * 9)
                            .offset(y: CGFloat(depth + 1) * 5)
                    }
                }
            }
            .padding(.bottom, CGFloat(under) * 5)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .onTapGesture {
                if opensToCheck { open(card) }
            }
            .help(opensToCheck ? "Open in To Check" : "")
            .contextMenu { cardMenu(card) }
            .id(card.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(opensToCheck ? .isButton : [])
            .accessibilityIdentifier("chat.savedCards.card.\(card.id)")
    }

    private func cardFill(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            // In dark mode the control colour is the pane's own; a touch of
            // white lifts the card off it, as To Check does.
            .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    private func face(_ card: ChatSavedCard) -> some View {
        let isSetAside: Bool = {
            switch card.standing {
            case .skipped, .notOffered: return true
            case .toCheck, .kept: return false
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                standing(card.standing)
            }
            .frame(minHeight: 16)
            .padding(.bottom, 8)
            Text(card.face.front.foldingMathSpans())
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.frontImages.isEmpty {
                MemoryCardImageGrid(images: card.face.frontImages, animationStartsAtOnce: false)
                    .padding(.top, 10)
            }
            MemoryCardFold()
                .padding(.vertical, 10)
            Text(card.face.back.foldingMathSpans())
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !card.face.backImages.isEmpty {
                MemoryCardImageGrid(images: card.face.backImages, animationStartsAtOnce: false)
                    .padding(.top, 10)
            }
        }
        .opacity(isSetAside ? 0.5 : 1)
    }

    @ViewBuilder
    private func standing(_ standing: ChatSavedCard.Standing) -> some View {
        switch standing {
        case .toCheck:
            EmptyView()
        case .kept:
            Label("Kept", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .skipped:
            Label("Skipped", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notOffered:
            Text("No longer offered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Drafted more than 14 days ago, or the same card as one already gone through")
        }
    }

    @ViewBuilder
    private func cardMenu(_ card: ChatSavedCard) -> some View {
        if let entry = card.toCheck {
            Button("Open in To Check") { open(card) }
            Button("Keep") { keep([entry]) }
        }
        if let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            Button("Show Passage") {
                Task { await vm.openLinkedSourceInReader(card.sourceID, passage: quote) }
            }
        }
    }

    // MARK: The actions

    private func footer(_ cards: [ChatSavedCard], page: Int) -> some View {
        let waiting = cards.compactMap(\.toCheck)
        // Check Cards opens at the card on top when it waits, else the first
        // that does.
        let target = cards[page].toCheck != nil ? cards[page] : cards.first { $0.toCheck != nil }
        return HStack(spacing: 12) {
            Spacer(minLength: 8)
            Button(waiting.count == 1 ? "Keep" : "Keep All") { keep(waiting) }
                .font(.callout)
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -5, tint: .accentColor))
                .disabled(isKeeping)
                .help(waiting.count == 1 ? "Keep the card still to check" : "Keep the \(waiting.count) cards still to check")
                .accessibilityIdentifier("chat.savedCards.keepAll")
            // The Space's dark pill, as every primary action outside a
            // sheet (docs/ui-design.md).
            SpaceDarkPillButton(title: "Check Cards", systemImage: nil, image: nil) {
                if let target { open(target) }
            }
            .help("Open To Check beside the chat, at this card")
            .accessibilityIdentifier("chat.savedCards.check")
        }
    }

    private func open(_ card: ChatSavedCard) {
        vm.openChatSavedCard(
            sourceID: card.sourceID,
            cardID: card.toCheck?.cardID,
            in: windowState ?? vm.activeWindowState
        )
        onOpenedInMemory?()
    }

    /// Keeps the cards as drafted, as To Check's Keep All does; the read that
    /// the kept cards set off redraws them kept.
    private func keep(_ entries: [MemoryCardToCheck]) {
        guard !entries.isEmpty, !isKeeping else { return }
        isKeeping = true
        Task {
            await vm.triageCardsToCheck(MemoryCardTriage.keepAll(entries))
            isKeeping = false
        }
    }

    /// Reads the cards, and while the read finds none or fails, reads again
    /// for as long as the deck is on screen: at once, then further and further
    /// apart, then every ten seconds. The cards of a reply a moment old can read
    /// as none for longer than a few seconds (a popover opened right after the
    /// reply said "not on this Mac" while the next open drew both cards), and
    /// a chat opened on another Mac waits for their rows to arrive. So an empty
    /// read is never the last word. Until about ten seconds have passed the deck
    /// keeps its spinner; after that it says what it found and keeps looking.
    /// Only a read that found cards is remembered for the next time it opens.
    private func load() async {
        let pauses: [Double] = [0.5, 1, 1.5, 2, 2, 3]
        var waited = 0.0
        var attempt = 0
        var lastWasEmpty = false
        while !Task.isCancelled {
            if let read = await vm.chatSavedCards(saved) {
                if !read.isEmpty {
                    readFailed = false
                    cards = read
                    ChatSavedCardsMemory.cards["\(saved.destination)"] = read
                    if page >= read.count { page = max(0, read.count - 1) }
                    return
                }
                lastWasEmpty = true
            }
            if waited >= 10 { showNothingFound(lastWasEmpty: lastWasEmpty) }
            let pause = attempt < pauses.count ? pauses[attempt] : 10
            attempt += 1
            waited += pause
            try? await Task.sleep(for: .seconds(pause))
        }
    }

    /// Says what the reads found: the cards are not here (never from a stale
    /// remembered empty deck) or, when every read failed and none answered,
    /// that they could not be read.
    private func showNothingFound(lastWasEmpty: Bool) {
        ChatSavedCardsMemory.cards["\(saved.destination)"] = nil
        if lastWasEmpty {
            readFailed = false
            if cards != [] { cards = [] }
        } else {
            readFailed = cards == nil
        }
    }
}

/// What `ReviewChatSavedCardsView` last showed, per set of saved cards, for
/// the next time the deck opens. None of it is stored or synced, and a read
/// replaces it as soon as it lands.
@MainActor
enum ChatSavedCardsMemory {
    static var cards: [String: [ChatSavedCard]] = [:]
    static var pages: [String: Int] = [:]
}
