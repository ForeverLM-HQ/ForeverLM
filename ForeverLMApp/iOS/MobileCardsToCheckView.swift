import SwiftUI

// Going through cards on the iPhone and iPad (docs/memory-design.md, "Cards to check on the iPhone"):
// To Check, the Mac's `MemoryCardsToCheckView` on a phone — the cards drafted from sources and not yet
// kept or skipped, a source at a time, each with Keep, Edit and Skip, and a source's Keep All and Skip
// All — and the editor a card to check and a kept card share. What a decision writes is
// `MobileCardTriageWriter`'s; what a kept card's menu writes, `MobileCardEditWriter`'s. Each card is
// drawn as the card it would be, in the deck's look (docs/memory-design.md, "How a card looks";
// `Shared/Views/MemoryCardDeck.swift`): paper, its kind in small tracked words, the front in the
// review's serif, the fold, the back and why.

/// To Check over every notebook or one: the Memory screen's section, and the screen a notebook's
/// Studio Cards row pushes while cards wait. Opening it reads only. A decided card leaves the list at
/// once and comes back only if the phone could not write it, which an alert says.
struct MobileCardsToCheckList<Header: View>: View {
    let scope: MemoryReviewScope
    /// Opens a card's source in the Reader.
    let openSource: (String) -> Void
    /// What sits above the cards (the Memory screen's section picker).
    @ViewBuilder let header: () -> Header

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var cards: [MemoryCardToCheck] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    /// Cards decided and on their way to the replica, hidden meanwhile.
    @State private var decided: Set<String> = []
    @State private var editing: MemoryCardToCheck?
    @State private var refusal: String?

    private var visible: [MemoryCardToCheck] { cards.filter { !decided.contains($0.cardID) } }

    var body: some View {
        let visible = visible
        let groups = MemoryCardTriage.grouped(visible)
        List {
            header()
            if groups.isEmpty {
                Text(emptyLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("memory.toCheck.empty")
            } else {
                if let summary = MemoryCardTriage.summary(visible) {
                    Text(summary)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("memory.toCheck.summary")
                }
                // A source heads its cards as a row of its own, as the Mac's list does: a section
                // header would be drawn in the list's grey and pinned over the cards.
                ForEach(groups) { group in
                    groupHeader(group)
                    ForEach(group.cards) { card in
                        cardRow(card)
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: "\(scope)#\(vm.memoryCardsRevision)") { await load() }
        .sheet(item: $editing) { card in
            MobileCardEditorSheet(
                title: "Edit Card",
                confirmTitle: "Keep",
                face: card.face,
                startsOver: { _ in false }
            ) { edit in
                editing = nil
                decide([MemoryCardTriageDecision(card: card, action: .keepEdited(edit))])
            }
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

    // MARK: A source

    /// The source's title and how many of its cards wait, and its ⋯: Keep All, Skip All, Open Source.
    private func groupHeader(_ group: MemoryCardTriage.Group) -> some View {
        HStack(alignment: .center, spacing: MobileDesign.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceTitle(group.sourceID))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(group.cards.count == 1 ? "1 card" : "\(group.cards.count) cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: MobileDesign.Spacing.small)
            Menu {
                Button("Keep All", systemImage: "checkmark") {
                    decide(MemoryCardTriage.keepAll(group.cards, unticked: []))
                }
                Button("Skip All", systemImage: "xmark", role: .destructive) {
                    decide(group.cards.map { MemoryCardTriageDecision(card: $0, action: .skip) })
                }
                if vm.sourcesByID[group.sourceID] != nil {
                    Divider()
                    Button("Open Source", systemImage: "doc.text") { openSource(group.sourceID) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: MobileDesign.Metrics.minimumTouchTarget, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            // Quiet ink, never the accent a menu's label takes by default.
            .tint(.secondary)
            .accessibilityLabel("Cards from \(sourceTitle(group.sourceID))")
            .accessibilityIdentifier("memory.toCheck.source.\(group.sourceID)")
        }
        .padding(.top, MobileDesign.Spacing.medium)
        .listRowInsets(EdgeInsets(top: 0, leading: MobileDesign.Spacing.large, bottom: 0, trailing: MobileDesign.Spacing.small))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: A card

    /// A card on its paper, lying flatter than the review's, with Skip and Edit as words and Keep as
    /// the accent's pale pill under it, as the Mac's To Check draws one.
    private func cardRow(_ card: MemoryCardToCheck) -> some View {
        let shape = RoundedRectangle(cornerRadius: MobileToCheckCardMetrics.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            cardFace(card)
            cardActions(card)
                .padding(.top, MobileDesign.Spacing.small)
        }
        .padding(.horizontal, 18)
        .padding(.top, MobileDesign.Spacing.large)
        .padding(.bottom, MobileDesign.Spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCardSurface(cornerRadius: MobileToCheckCardMetrics.cornerRadius, raised: false)
        .contentShape(.contextMenuPreview, shape)
        .listRowInsets(EdgeInsets(
            top: MobileDesign.Spacing.small - 2,
            leading: MobileDesign.Spacing.large,
            bottom: MobileDesign.Spacing.small - 2,
            trailing: MobileDesign.Spacing.large
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Keep", systemImage: "checkmark") { decide([MemoryCardTriageDecision(card: card, action: .keep)]) }
                .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Skip", systemImage: "xmark") { decide([MemoryCardTriageDecision(card: card, action: .skip)]) }
                .tint(.gray)
        }
        .contextMenu {
            Button("Keep", systemImage: "checkmark") { decide([MemoryCardTriageDecision(card: card, action: .keep)]) }
            Button("Edit…", systemImage: "pencil") { editing = card }
            Button("Skip", systemImage: "xmark") { decide([MemoryCardTriageDecision(card: card, action: .skip)]) }
            if vm.sourcesByID[card.sourceID] != nil {
                Divider()
                Button("Open Source", systemImage: "doc.text") { openSource(card.sourceID) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Keep") { decide([MemoryCardTriageDecision(card: card, action: .keep)]) }
        .accessibilityAction(named: "Edit") { editing = card }
        .accessibilityAction(named: "Skip") { decide([MemoryCardTriageDecision(card: card, action: .skip)]) }
        .accessibilityIdentifier("memory.toCheck.card.\(card.cardID)")
    }

    /// Its kind, the front in the review's serif, the fold, the back, why it holds, and how many
    /// pictures it carries.
    private func cardFace(_ card: MemoryCardToCheck) -> some View {
        let tags = [card.face.difficulty?.rawValue, card.kind == .legacy ? "From before cards" : nil].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 0) {
            if !tags.isEmpty {
                MemoryCardTagLine(tags: tags)
                    .accessibilityLabel(tags.map(\.capitalized).joined(separator: ", "))
                    .padding(.bottom, 10)
            }
            Text(card.face.front)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            MemoryCardFold()
                .padding(.vertical, MobileDesign.Spacing.medium)
            Text(card.face.back)
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(4)
            if !card.face.why.isEmpty {
                MemoryCardWhyLine(why: card.face.why)
                    .lineLimit(3)
                    .padding(.top, 10)
            }
            let pictures = card.face.frontImages.count + card.face.backImages.count
            if pictures > 0 {
                Label(pictures == 1 ? "1 picture" : "\(pictures) pictures", systemImage: "photo.on.rectangle.angled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, MobileDesign.Spacing.small)
            }
        }
    }

    private func cardActions(_ card: MemoryCardToCheck) -> some View {
        HStack(spacing: 0) {
            Button {
                decide([MemoryCardTriageDecision(card: card, action: .skip)])
            } label: {
                Label("Skip", systemImage: "xmark")
            }
            .buttonStyle(MobileMemoryPillStyle(kind: .quiet, height: MobileToCheckCardMetrics.actionHeight))
            .accessibilityIdentifier("memory.toCheck.skip.\(card.cardID)")
            Button {
                editing = card
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(MobileMemoryPillStyle(kind: .quiet, height: MobileToCheckCardMetrics.actionHeight))
            .accessibilityIdentifier("memory.toCheck.edit.\(card.cardID)")
            Spacer(minLength: 0)
            Button {
                decide([MemoryCardTriageDecision(card: card, action: .keep)])
            } label: {
                Label("Keep", systemImage: "checkmark")
            }
            .buttonStyle(MobileMemoryPillStyle(kind: .tinted, height: MobileToCheckCardMetrics.actionHeight))
            .accessibilityIdentifier("memory.toCheck.keep.\(card.cardID)")
        }
        .labelStyle(.titleAndIcon)
        .imageScale(.small)
        // The first word lines up with the card's text, its pill's inset outside it.
        .padding(.leading, -MobileDesign.Spacing.medium)
    }

    // MARK: Deciding

    /// Hides the decided cards at once and writes the decisions; a card the phone could not write
    /// comes back, and the alert says why.
    private func decide(_ decisions: [MemoryCardTriageDecision]) {
        guard !decisions.isEmpty else { return }
        decided.formUnion(decisions.map(\.card.cardID))
        Task {
            let result = await vm.triageCardsToCheck(decisions)
            decided.subtract(result.failed.map(\.cardID))
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

/// A card to check's paper and its actions' height (`MobileCardsToCheckList` is generic over its
/// header, which holds no stored statics).
private enum MobileToCheckCardMetrics {
    static let cornerRadius: CGFloat = 12
    /// A card's actions are drawn this tall; each still answers a 44-point tap.
    static let actionHeight: CGFloat = 34
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
