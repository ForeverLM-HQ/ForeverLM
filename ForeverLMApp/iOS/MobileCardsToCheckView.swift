import SwiftUI

// Going through cards on the iPhone and iPad (docs/memory-design.md, "Cards to check on the iPhone"):
// To Check, the Mac's `MemoryCardsToCheckView` on a phone — the cards drafted from sources and not yet
// kept or skipped, dealt a card at a time as the review deals them, with Skip, Edit and Keep under the
// card, and a source's Keep All and Skip All in the ⋯ over it — and the editor a card to check and a
// kept card share. What a decision writes is `MobileCardTriageWriter`'s; what a kept card's menu
// writes, `MobileCardEditWriter`'s. The card is the review's (docs/memory-design.md, "How a card
// looks"; `Shared/Views/MemoryCardDeck.swift`): paper, its kind in small tracked words, the front in
// the review's serif, the fold, the back and why, the edges of the cards still to come under it.

/// To Check over every notebook or one: the Memory screen's section, and the screen a notebook's
/// Studio Cards row pushes while cards wait. A card at a time since 2026-10-12, as on the Mac (product
/// owner: "more intuitive if the review process just shows cards that i go through … and then i can
/// say keep / edit etc"): over the card its source, which opens it, its place ("3 of 15") and the
/// round's strip; under it Skip and Edit, pale, and Keep, dark. Swiping the card right keeps it and
/// left skips it, and it goes off that way as an answered card does. Opening it reads only. A decided
/// card leaves at once and comes back only if the phone could not write it, which an alert says.
struct MobileCardsToCheckList<Header: View>: View {
    let scope: MemoryReviewScope
    /// Opens a card's source in the Reader.
    let openSource: (String) -> Void
    /// What sits above the card (the Memory screen's section picker).
    @ViewBuilder let header: () -> Header

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cards: [MemoryCardToCheck] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    /// Cards decided and on their way to the replica, hidden meanwhile.
    @State private var decided: Set<String> = []
    /// What this sitting decided, in order: kept or not. The strip and the count read it; a card the
    /// phone could not write leaves it.
    @State private var gone: [Gone] = []
    @State private var editing: MemoryCardToCheck?
    @State private var confirmingSkipAll: [MemoryCardToCheck]?
    @State private var refusal: String?
    /// Where the card in front goes once decided: Keep to the right, Skip to the left.
    @State private var exitEdge: HorizontalEdge = .trailing
    /// How far the card in front is dragged sideways.
    @State private var drag: CGFloat = 0
    @ScaledMetric(relativeTo: .title2) private var frontSize = MemoryCardMetrics.frontSize
    @ScaledMetric(relativeTo: .body) private var backSize = MemoryCardMetrics.backSize

    private struct Gone: Equatable {
        let cardID: String
        let kept: Bool
    }

    private var visible: [MemoryCardToCheck] { cards.filter { !decided.contains($0.cardID) } }

    var body: some View {
        let visible = visible
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.xLarge) {
                header()
                if let card = visible.first {
                    sitting(card, waiting: visible.count)
                        .frame(maxWidth: MobileToCheckMetrics.columnWidth)
                        .frame(maxWidth: .infinity)
                } else if hasLoaded, !gone.isEmpty {
                    doneState
                } else {
                    Text(emptyLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("memory.toCheck.empty")
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.top, MobileDesign.Spacing.small)
            .padding(.bottom, MobileDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(scope)#\(vm.memoryCardsRevision)") { await load() }
        .sensoryFeedback(.impact(weight: .light), trigger: gone.count)
        .sheet(item: $editing) { card in
            MobileCardEditorSheet(
                title: "Edit Card",
                confirmTitle: "Keep",
                face: card.face,
                startsOver: { _ in false }
            ) { edit in
                editing = nil
                decide(card, .keepEdited(edit))
            }
        }
        .confirmationDialog(
            "Skip the rest of this source's cards?",
            isPresented: Binding(
                get: { confirmingSkipAll != nil },
                set: { if !$0 { confirmingSkipAll = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingSkipAll
        ) { cards in
            Button("Skip All", role: .destructive) { decideAll(cards, keep: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cards from before cards are retired and never asked again.")
        }
        .alert("A card stayed to check", isPresented: Binding(
            get: { refusal != nil },
            set: { if !$0 { refusal = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
        .accessibilityIdentifier("memory.toCheck")
    }

    private var emptyLine: String {
        guard hasLoaded else { return " " }
        return loadFailed ? "The cards to check could not be read." : "Nothing to check"
    }

    private func load() async {
        let read = await vm.cardsToCheck(scope: scope)
        guard !Task.isCancelled else { return }
        loadFailed = read == nil
        cards = read ?? []
        // A fresh read: what was written is gone, what the phone could not write is back.
        decided.formIntersection(Set(cards.map(\.cardID)))
        hasLoaded = true
    }

    /// Every card gone through: what became of them.
    private var doneState: some View {
        let kept = gone.filter(\.kept).count
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
            Text("All checked")
                .font(.title3.weight(.semibold))
            Text(MobileToCheckMetrics.doneLine(kept: kept, skipped: gone.count - kept))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.toCheck.done")
    }

    // MARK: The card in front

    @ViewBuilder
    private func sitting(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.large) {
            progress(card, waiting: waiting)
            deck(card, waiting: waiting)
            actions(card)
            if gone.isEmpty {
                // What the buttons do, to someone who has never seen them.
                Text("Keep a card and Review will ask it. Skip it and it is gone. Swipe right to keep, left to skip.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("memory.toCheck.hint")
            }
        }
    }

    /// Over the card: its source, which opens it, its place, the ⋯ for its source, and the strip of
    /// the cards gone through.
    private func progress(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        let title = sourceTitle(card.sourceID)
        let opens = vm.sourcesByID[card.sourceID] != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: MobileDesign.Spacing.small) {
                Button {
                    openSource(card.sourceID)
                } label: {
                    // A card that stands on several sources names the first and counts the rest.
                    Text(card.sourceIDs.count > 1 ? "\(title) +\(card.sourceIDs.count - 1)" : title)
                        .fontWeight(.medium)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!opens)
                .accessibilityLabel(card.sourceIDs.count > 1 ? "From \(card.sourceIDs.map(sourceTitle).joined(separator: ", "))" : "From \(title)")
                .accessibilityHint(opens ? "Opens the source" : "")
                .accessibilityIdentifier("memory.toCheck.source")
                Text("\(gone.count + 1) of \(gone.count + waiting)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityIdentifier("memory.toCheck.place")
                sourceMenu(card, opens: opens)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            MemoryRoundStrip(
                marks: gone.map { $0.kept ? .remembered : .skipped }
                    + [.current]
                    + Array(repeating: .upcoming, count: max(0, waiting - 1))
            )
        }
    }

    /// Keep All and Skip All for the rest of the card's source, and Open Source.
    private func sourceMenu(_ card: MemoryCardToCheck, opens: Bool) -> some View {
        let rest = visible.filter { $0.sourceID == card.sourceID }
        return Menu {
            Section(rest.count == 1 ? "1 card from this source" : "\(rest.count) cards from this source") {
                Button("Keep All", systemImage: "checkmark") { decideAll(rest, keep: true) }
                Button("Skip All", systemImage: "xmark", role: .destructive) {
                    if rest.contains(where: { $0.kind == .legacy }) {
                        confirmingSkipAll = rest
                    } else {
                        decideAll(rest, keep: false)
                    }
                }
            }
            if opens {
                Button("Open Source", systemImage: "doc.text") { openSource(card.sourceID) }
            }
            Button("Copy Card ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = card.cardID }
            // The card's other sources, each of which opens.
            ForEach(card.sourceIDs.dropFirst(), id: \.self) { id in
                if vm.sourcesByID[id] != nil {
                    Button("Open \(sourceTitle(id))", systemImage: "doc.text") { openSource(id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(minWidth: MobileDesign.Metrics.minimumTouchTarget, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        // Quiet ink, never the accent a menu's label takes by default.
        .tint(.secondary)
        .accessibilityLabel("More")
        .accessibilityIdentifier("memory.toCheck.more")
    }

    /// The card in front, the edges of those still to come under it, the toss and the deal between
    /// them; dragged sideways, it follows the finger and tips.
    private func deck(_ card: MemoryCardToCheck, waiting: Int) -> some View {
        ZStack {
            cardFace(card)
                .modifier(MemoryCardToss(offset: drag, angle: Double(drag / 40), opacity: 1))
                .overlay(alignment: drag > 0 ? .topLeading : .topTrailing) { swipeWord }
                .simultaneousGesture(swipe(card))
                .id(card.cardID)
                .transition(.memoryCard(leavingTo: exitEdge, reduceMotion: reduceMotion))
                .contextMenu {
                    Button("Keep", systemImage: "checkmark") { decide(card, .keep) }
                    Button("Edit…", systemImage: "pencil") { editing = card }
                    Button("Skip", systemImage: "xmark") { decide(card, .skip) }
                    if vm.sourcesByID[card.sourceID] != nil {
                        Divider()
                        Button("Open Source", systemImage: "doc.text") { openSource(card.sourceID) }
                    }
                }
                .accessibilityAction(named: "Keep") { decide(card, .keep) }
                .accessibilityAction(named: "Edit") { editing = card }
                .accessibilityAction(named: "Skip") { decide(card, .skip) }
        }
        .background(alignment: .bottom) {
            MemoryDeckEdges(remaining: waiting - 1)
        }
        .padding(.bottom, MemoryDeckEdges.depth)
    }

    /// KEEP or SKIP over the card's corner while it is dragged far enough to decide.
    @ViewBuilder
    private var swipeWord: some View {
        if abs(drag) > MobileToCheckMetrics.swipeThreshold * 0.5 {
            Text(drag > 0 ? "KEEP" : "SKIP")
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.secondary, lineWidth: 1.5))
                .opacity(min(1, abs(drag) / MobileToCheckMetrics.swipeThreshold))
                .padding(MobileDesign.Spacing.large)
                .accessibilityHidden(true)
        }
    }

    /// A sideways swipe: past the threshold, right keeps and left skips; short of it, the card
    /// springs back. A mostly vertical drag is the scroll's.
    private func swipe(_ card: MemoryCardToCheck) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                let width = drag
                guard abs(width) > MobileToCheckMetrics.swipeThreshold
                    || abs(value.predictedEndTranslation.width) > MobileToCheckMetrics.swipeThreshold * 2,
                    width != 0
                else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = 0 }
                    return
                }
                decide(card, width > 0 ? .keep : .skip)
            }
    }

    /// Its kind, the front in the review's serif, its pictures, the fold, the back and why it holds.
    private func cardFace(_ card: MemoryCardToCheck) -> some View {
        let tags = [card.face.difficulty?.rawValue, card.kind == .legacy ? "From before cards" : nil].compactMap { $0 }
        let inset: CGFloat = horizontalSizeClass == .regular ? 34 : 24
        return VStack(alignment: .leading, spacing: 0) {
            if !tags.isEmpty {
                MemoryCardTagLine(tags: tags)
                    .accessibilityLabel(tags.map(\.capitalized).joined(separator: ", "))
                    .padding(.bottom, MobileDesign.Spacing.medium)
            }
            Text(card.face.front)
                .font(.system(size: frontSize, weight: .regular, design: .serif))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("memory.toCheck.front")
            if !card.face.frontImages.isEmpty {
                MobileMemoryCardImageGrid(images: card.face.frontImages, sourceID: card.sourceID)
                    .padding(.top, MobileDesign.Spacing.large)
            }
            MemoryCardFold()
                .padding(.vertical, 20)
            Text(card.face.back)
                .font(.system(size: backSize))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Answer: \(card.face.back)")
                .accessibilityIdentifier("memory.toCheck.back")
            if !card.face.backImages.isEmpty {
                MobileMemoryCardImageGrid(images: card.face.backImages, sourceID: card.sourceID)
                    .padding(.top, MobileDesign.Spacing.large)
            }
            if !card.face.why.isEmpty {
                MemoryCardWhyLine(why: card.face.why)
                    .accessibilityElement(children: .combine)
                    .padding(.top, 14)
            }
        }
        .padding(inset)
        .frame(
            maxWidth: .infinity,
            minHeight: verticalSizeClass == .compact ? MobileToCheckMetrics.compactHeightCardMinimum : MemoryCardMetrics.cardMinimumHeight,
            alignment: .topLeading
        )
        .memoryCardSurface()
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: MemoryCardMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.toCheck.card")
    }

    /// Skip and Edit, pale; Keep, the dark pill that moves on. Stacked at the accessibility sizes.
    private func actions(_ card: MemoryCardToCheck) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: MobileDesign.Spacing.small))
            : AnyLayout(HStackLayout(spacing: MobileDesign.Spacing.small))
        return layout {
            Button("Skip") { decide(card, .skip) }
                .buttonStyle(MobileMemoryPillStyle(kind: .secondary))
                .accessibilityHint("Drops this card for good")
                .accessibilityIdentifier("memory.toCheck.skip")
            Button("Edit") { editing = card }
                .buttonStyle(MobileMemoryPillStyle(kind: .secondary))
                .accessibilityHint("Keeps this card in your own words")
                .accessibilityIdentifier("memory.toCheck.edit")
            Button {
                decide(card, .keep)
            } label: {
                Text("Keep")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MobileMemoryPillStyle(kind: .primary))
            .accessibilityHint("Review will ask it")
            .accessibilityIdentifier("memory.toCheck.keep")
        }
        .frame(maxWidth: horizontalSizeClass == .regular ? MobileToCheckMetrics.regularBarWidth : .infinity)
        .frame(maxWidth: .infinity)
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

    /// Hides the decided cards at once, deals the next, and writes the decisions; a card the phone
    /// could not write comes back, and the alert says why.
    private func decide(_ decisions: [MemoryCardTriageDecision]) {
        guard !decisions.isEmpty else { return }
        withAnimation(MobileToCheckMetrics.dealAnimation) {
            decided.formUnion(decisions.map(\.card.cardID))
            gone += decisions.map { decision in
                if case .skip = decision.action { return Gone(cardID: decision.card.cardID, kept: false) }
                return Gone(cardID: decision.card.cardID, kept: true)
            }
        }
        // The next card comes in square.
        drag = 0
        Task {
            let result = await vm.triageCardsToCheck(decisions)
            let failed = Set(result.failed.map(\.cardID))
            decided.subtract(failed)
            gone.removeAll { failed.contains($0.cardID) }
            if let failure = result.failed.first {
                refusal = result.failed.count == 1 ? failure.reason : "\(result.failed.count) cards stayed to check. \(failure.reason)"
            }
        }
    }

    private func sourceTitle(_ sourceID: String) -> String {
        let title = vm.sourcesByID[sourceID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Source not in the library" : title
    }
}

/// To Check's measures and words (`MobileCardsToCheckList` is generic over its header, which holds no
/// stored statics).
enum MobileToCheckMetrics {
    /// The column at regular width, the review's.
    static let columnWidth: CGFloat = 600
    /// The buttons' width at regular width, the review's answer bar's.
    static let regularBarWidth: CGFloat = 420
    /// A card's least height at compact height, where it and the buttons share a short screen.
    static let compactHeightCardMinimum: CGFloat = 170
    /// How far a card is dragged before letting go keeps or skips it.
    static let swipeThreshold: CGFloat = 110
    static let dealAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// "You kept 9 cards and skipped 3. Review will ask the ones you kept."
    static func doneLine(kept: Int, skipped: Int) -> String {
        let keptCards = kept == 1 ? "1 card" : "\(kept) cards"
        switch (kept, skipped) {
        case (0, _): return "You skipped them all."
        case (_, 0): return "You kept \(keptCards). Review will ask them."
        default: return "You kept \(keptCards) and skipped \(skipped). Review will ask the ones you kept."
        }
    }
}

/// To Check narrowed to one notebook, pushed from its Studio's Cards row while cards wait there.
struct MobileCardsToCheckScreen: View {
    let notebookID: String
    let openSource: (String) -> Void

    var body: some View {
        MobileCardsToCheckList(scope: .notebook(notebookID), openSource: openSource) { EmptyView() }
            .navigationTitle("Cards to Check")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("notebook.cardsToCheck")
    }
}

// MARK: - Editing a card

/// A card's front, back and why: a card to check kept in the learner's words (Keep), or a kept card
/// changed (Save). When `startsOver` says the change makes a new card — a kept card's new back or why —
/// the sheet asks first, in the Mac's words.
struct MobileCardEditorSheet: View {
    let title: String
    let confirmTitle: String
    let face: MemoryCard
    let startsOver: (MemoryCardEdit) -> Bool
    let confirm: (MemoryCardEdit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var front: String
    @State private var back: String
    @State private var why: String
    @State private var confirmingStartOver = false

    init(
        title: String,
        confirmTitle: String,
        face: MemoryCard,
        wording: String? = nil,
        startsOver: @escaping (MemoryCardEdit) -> Bool,
        confirm: @escaping (MemoryCardEdit) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.face = face
        self.startsOver = startsOver
        self.confirm = confirm
        _front = State(initialValue: wording ?? face.front)
        _back = State(initialValue: face.back)
        _why = State(initialValue: face.why.joined(separator: "\n"))
    }

    private var edit: MemoryCardEdit {
        MemoryCardEdit(
            front: front.trimmingCharacters(in: .whitespacesAndNewlines),
            back: back.trimmingCharacters(in: .whitespacesAndNewlines),
            why: why.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            frontImages: face.frontImages,
            backImages: face.backImages
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Front") {
                    TextField("Front", text: $front, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("memory.editor.front")
                }
                Section("Back") {
                    TextField("Back", text: $back, axis: .vertical)
                        .lineLimit(2...8)
                        .accessibilityIdentifier("memory.editor.back")
                }
                Section("Why") {
                    TextField("Why", text: $why, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("memory.editor.why")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        if startsOver(edit) {
                            confirmingStartOver = true
                        } else {
                            confirm(edit)
                        }
                    }
                    .disabled(edit.front.isEmpty || edit.back.isEmpty)
                    .accessibilityIdentifier("memory.editor.confirm")
                }
            }
            .alert("Start this card over?", isPresented: $confirmingStartOver) {
                Button("Start Over") { confirm(edit) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new answer makes a new card, first asked tomorrow. Its answers so far stay with the old one.")
            }
        }
        .accessibilityIdentifier("memory.editor")
    }
}

// MARK: - A kept card's menu

/// The Mac's All Cards menu on a kept card: Edit Card…, Start Over…, Always Ask in Its Own Words (or
/// Let Its Wording Vary), Retire…, and Open Source when the phone holds it.
struct MobileKeptCardMenuItems: View {
    let alwaysAsks: Bool
    let canOpenSource: Bool
    let edit: () -> Void
    let startOver: () -> Void
    let setAlwaysAsk: (Bool) -> Void
    let retire: () -> Void
    let openSource: () -> Void

    var body: some View {
        Button("Edit Card…", systemImage: "pencil", action: edit)
        Button("Start Over…", systemImage: "arrow.counterclockwise", action: startOver)
        if alwaysAsks {
            Button("Let Its Wording Vary", systemImage: "shuffle") { setAlwaysAsk(false) }
        } else {
            Button("Always Ask in Its Own Words", systemImage: "text.quote") { setAlwaysAsk(true) }
        }
        Button("Retire…", systemImage: "archivebox", role: .destructive, action: retire)
        if canOpenSource {
            Divider()
            Button("Open Source", systemImage: "doc.text", action: openSource)
        }
    }
}
