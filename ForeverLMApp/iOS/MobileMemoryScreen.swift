import SwiftUI

// Memory on the iPhone and iPad (docs/memory-design.md, "The Memory screen
// on the iPhone"): the Mac's Memory pane (`App/MemoryPane.swift`) over every
// notebook, and Home's Memory strip, the Mac's.
// Review draws today's cards as the Mac's deck ("10", "cards today", "6 due ·
// 4 new"), starts the card review (Start Review, Keep Going, Practice N New
// Cards) and draws the history grid; To Check goes through the cards drafted
// from sources a card at a time (Keep, Edit, Skip, `MobileCardsToCheckList`); All Cards lists
// every kept card, searched, by
// source, a tap editing it and its menu starting it over, holding it to its
// own words or retiring it. The pure rules are in `MobileCardReview.swift`
// (`MobileMemoryScreenCopy`, `MobileMemoryHistoryDays`,
// `MobileMemoryHistoryLayout`) and `MobileCardTriage.swift`.

/// The Memory screen's sections: the Mac's `MemoryPaneSection`.
enum MobileMemorySection: String, CaseIterable, Identifiable, Hashable {
    case review
    case toCheck
    case allCards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Review"
        case .toCheck: return "To Check"
        case .allCards: return "All Cards"
        }
    }
}

/// The Memory screen. Opening it reads what the phone holds — today's cards,
/// the cards to check, the kept cards, the review chats, and the day's
/// minutes from iCloud — and writes nothing; Start Review, Keep Going and
/// Practice push the card review, and To Check's and All Cards' actions
/// write the cards they are on.
struct MobileMemoryScreen: View {
    /// Pushes a route on the shell's stack: the card review, practice, an
    /// earlier day's review chat, a card's source.
    let open: (MobileShellRoute) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var goal = MobileMemoryGoalModel.shared
    @State private var section: MobileMemorySection = .review
    @State private var counts = MemoryCardDayCounts.zero
    @State private var cards: [MemoryCardListing] = []
    /// Each kept card's Card, by item id: its wording as asked and whether
    /// it is held to its own words.
    @State private var records: [String: MobileCardRecord] = [:]
    @State private var reviewChats = MobileMemoryHistoryDays.Days.none
    @State private var hasLoaded = false
    @State private var query = ""
    @State private var editing: MemoryCardListing?
    @State private var confirmingStartOver: MemoryCardListing?
    @State private var confirmingRetire: MemoryCardListing?
    @State private var writeError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// How many cards wait, on the deck's card: the Mac's 56 points, scaled
    /// with the reader's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var deckCountSize: CGFloat = 56

    var body: some View {
        content
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.large)
            .task(id: loadKey) { await load() }
            // The day's minutes, every device's: what the promise, Keep Going
            // and the grid read. Coalesced, and a read only.
            .onAppear { goal.reload() }
            .sheet(item: $editing) { card in
                MobileCardEditorSheet(
                    title: "Edit Card",
                    confirmTitle: "Save",
                    face: card.face,
                    wording: wording(of: card),
                    startsOver: { MobileCardEditWriter.startsOver(card, $0) }
                ) { edit in
                    editing = nil
                    write("The card was not changed.") {
                        try await vm.applyCardEdit(edit, to: card, wording: wording(of: card))
                    }
                }
            }
            .alert("Start this card over?", isPresented: Binding(
                get: { confirmingStartOver != nil },
                set: { if !$0 { confirmingStartOver = nil } }
            ), presenting: confirmingStartOver) { card in
                Button("Start Over") {
                    write("The card could not be started over.") {
                        try await vm.startCardOver(card, edit: nil, wording: wording(of: card))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It comes back as a new card, first asked tomorrow. Its answers so far stay with the old one.")
            }
            .alert("Retire this card?", isPresented: Binding(
                get: { confirmingRetire != nil },
                set: { if !$0 { confirmingRetire = nil } }
            ), presenting: confirmingRetire) { card in
                Button("Retire", role: .destructive) {
                    write("The card was not retired.") { try await vm.retireCard(card) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It is never asked again.")
            }
            .alert("Not saved", isPresented: Binding(
                get: { writeError != nil },
                set: { if !$0 { writeError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(writeError ?? "")
            }
            .accessibilityIdentifier("memory.screen")
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .review: reviewSection
        case .toCheck: toCheckSection
        case .allCards: allCardsSection
        }
    }

    /// Read again whenever today's cards are dealt again (a sync's
    /// checkpoint, an answer saved) and when the day turns.
    private var loadKey: String {
        "\(vm.memoryCardsRevision)#\(MemoryReviewGoal.dayKey(for: Date()))"
    }

    private func load() async {
        let read = await vm.cardReviewRead(scope: .allNotebooks)
        let listings = await vm.keptCardListings()
        let held = await vm.cardRecords(itemIDs: listings.map(\.itemID))
        let chats = await vm.memoryReviewChatDays()
        guard !Task.isCancelled else { return }
        counts = read.counts
        cards = listings
        records = held
        reviewChats = chats
        hasLoaded = true
    }

    /// A kept card's change, written off the screen; a failure is said.
    private func write(_ failure: String, _ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                writeError = "\(failure) \(error.localizedDescription)"
            }
        }
    }

    /// The card as it is asked: the learner's rewording when they made one.
    private func wording(of card: MemoryCardListing) -> String {
        card.face.wording(state: records[card.itemID]?.state)
    }

    /// Until the first sync has brought sources, an empty read is not yet
    /// known to mean nothing is waiting, so the counts say nothing.
    private var knowsCards: Bool {
        hasLoaded && !vm.allSources.isEmpty
    }

    /// Review | To Check | All Cards. To Check shows only while cards wait
    /// to be checked, or while it is the section on screen, so deciding the
    /// last card never pulls it away (a section with nothing in it is not
    /// drawn; a notebook's Cards row still opens its own).
    private var shownSections: [MobileMemorySection] {
        MobileMemorySection.allCases.filter { $0 != .toCheck || vm.cardsToCheckTotal > 0 || section == .toCheck }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(shownSections) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 400)
        .accessibilityIdentifier("memory.screen.section")
    }

    // MARK: Review

    /// Today's card on the deck, the Mac pane's size (docs/memory-design.md,
    /// "How a card looks"): 300 points wide and at least 184 tall, shorter at
    /// compact height, and as wide as the column at the accessibility text
    /// sizes, where it grows with its words.
    private static let deckWidth: CGFloat = 300
    private static let deckHeight: CGFloat = 184
    private static let compactHeightDeckHeight: CGFloat = 140
    /// Start Review's narrowest, the Mac pane's.
    private static let primaryMinWidth: CGFloat = 200

    /// The Mac's Memory pane's Review: today's cards drawn
    /// as the deck the review deals — one card with how many there are, the
    /// edges of the rest under it — the done day's sentence where the card
    /// does not already say it, one dark Start Review with Practice a quiet
    /// word under it, and the history grid.
    private var reviewSection: some View {
        let state = MobileMemoryScreenCopy.state(goal: goal.snapshot)
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.xLarge) {
                sectionPicker
                VStack(spacing: 0) {
                    todayDeck(state: state)
                        .padding(.bottom, MemoryDeckEdges.depth)
                    if knowsCards, MobileMemoryScreenCopy.showsPromise(state: state, counts: counts),
                       let promise = MobileMemoryScreenCopy.promise(state: state) {
                        Text(promise)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, MobileDesign.Spacing.large)
                            .accessibilityIdentifier("memory.screen.promise")
                    }
                    actions(state: state)
                }
                .frame(maxWidth: .infinity)
                // Drawn once every device's minutes are read: a grid of the
                // chats alone would be lighter than the learner's days were.
                if goal.hasLoaded {
                    MobileMemoryHistoryGrid(
                        chatDays: reviewChats.chatDays,
                        answeredDays: reviewChats.answeredDays,
                        dayProgress: goal.historyDays
                    ) { day in
                        open(.savedChat(
                            sessionID: MobileMemoryHistoryDays.sessionID(day: day.key),
                            title: MemoryReviewSession.title(for: day.date)
                        ))
                    }
                    .padding(.top, MobileDesign.Spacing.medium)
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.top, MobileDesign.Spacing.small)
            .padding(.bottom, MobileDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mobileReadableWidth()
        }
        .accessibilityIdentifier("memory.screen.review")
    }

    /// Today's cards as a card on the deck, the Mac's `MemoryPane.todayDeck`:
    /// how many, "cards today", and "6 due · 4 new" under it; with none,
    /// what the day is instead. Blank paper until the counts are known.
    private func todayDeck(state: MemoryReviewCommitment.State) -> some View {
        let today = knowsCards ? counts.today : 0
        return VStack(spacing: 6) {
            if !knowsCards {
                Color.clear.frame(height: 1)
            } else if today > 0 {
                Text("\(today)")
                    .font(.system(size: deckCountSize, weight: .regular, design: .serif))
                    .monospacedDigit()
                Text(MobileMemoryScreenCopy.deckCaption(today: today))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let line = counts.todayLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(MemoryCardMetrics.smallWordsStyle)
                        .monospacedDigit()
                        .padding(.top, 2)
                }
            } else if case .done = state {
                Image(systemName: "checkmark")
                    .font(.title2.weight(.light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(MobileMemoryScreenCopy.emptyDeckTitle(state: state))
                    .font(.system(.title3, design: .serif))
                    .padding(.top, 4)
            } else {
                Text(MobileMemoryScreenCopy.emptyDeckTitle(state: state))
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, MobileDesign.Spacing.xLarge)
        .padding(.vertical, MobileDesign.Spacing.large)
        .frame(
            maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : Self.deckWidth,
            minHeight: verticalSizeClass == .compact ? Self.compactHeightDeckHeight : Self.deckHeight
        )
        .memoryCardSurface()
        .background(alignment: .bottom) {
            MemoryDeckEdges(remaining: today - 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!knowsCards)
        .accessibilityIdentifier("memory.screen.counts")
    }

    /// Start Review or Keep Going, the dark pill, and Practice N New Cards a
    /// quiet word under it: the Mac's pane's buttons. Each pushes the card
    /// review over every notebook, whose title changes the scope.
    @ViewBuilder
    private func actions(state: MemoryReviewCommitment.State) -> some View {
        let primary = knowsCards ? MobileMemoryScreenCopy.primaryTitle(state: state, counts: counts) : nil
        let practices = knowsCards && counts.practice > 0
        if primary != nil || practices {
            VStack(spacing: MobileDesign.Spacing.xSmall) {
                if let primary {
                    Button {
                        open(.cardReview(.allNotebooks))
                    } label: {
                        Text(primary)
                            .frame(minWidth: Self.primaryMinWidth)
                    }
                    .buttonStyle(MobileMemoryPillStyle(kind: .primary))
                    .accessibilityIdentifier("memory.screen.start")
                }
                if practices {
                    Button(MobileCardReviewCopy.practiceNewCards(counts.practice)) {
                        open(.cardPractice(.allNotebooks))
                    }
                    .buttonStyle(MobileMemoryPillStyle(kind: .quiet, height: MobileDesign.Metrics.minimumTouchTarget))
                    .accessibilityHint("Cards kept today, or past today's new cards, asked now")
                    .accessibilityIdentifier("memory.screen.practice")
                }
            }
            .padding(.top, MobileDesign.Spacing.large)
        }
    }

    // MARK: To check

    private var toCheckSection: some View {
        MobileCardsToCheckList(scope: .allNotebooks) { sourceID in
            open(.source(sourceID, notebookID: nil))
        } header: {
            sectionPicker
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: All cards

    private var allCardsSection: some View {
        let searched = MemoryCardCatalog.search(cards, query: query, wording: wording(of:), sourceTitle: sourceTitle(_:))
        let groups = MemoryCardCatalog.grouped(searched, by: .source, sourceTitle: sourceTitle(_:), notebooks: [])
        return List {
            sectionPicker
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(
                    top: MobileDesign.Spacing.small,
                    leading: MobileDesign.Spacing.large,
                    bottom: MobileDesign.Spacing.medium,
                    trailing: MobileDesign.Spacing.large
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if groups.isEmpty {
                Text(knowsCards ? (cards.isEmpty ? "No kept cards" : "No card matches") : " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("memory.screen.cardsEmpty")
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.cards) { card in
                            cardRow(card)
                        }
                    } header: {
                        Text("\(group.title) · \(group.cards.count)")
                            .textCase(nil)
                            .lineLimit(2)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search cards")
        .accessibilityIdentifier("memory.screen.cards")
    }

    /// A kept card: its wording, its back, and when it is next asked. A tap
    /// edits it (a new front rewords it, a new back or why starts it over);
    /// its menu is the Mac's All Cards menu.
    private func cardRow(_ card: MemoryCardListing) -> some View {
        let sourceID = openableSourceID(of: card)
        return Button {
            editing = card
        } label: {
            cardLabel(card)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu {
            MobileKeptCardMenuItems(
                alwaysAsks: records[card.itemID]?.alwaysAsk ?? false,
                canOpenSource: sourceID != nil,
                edit: { editing = card },
                startOver: { confirmingStartOver = card },
                setAlwaysAsk: { on in
                    write("The card's wording was not saved.") { try await vm.setCardAlwaysAsk(on, itemID: card.itemID) }
                },
                retire: { confirmingRetire = card },
                openSource: { if let sourceID { open(.source(sourceID, notebookID: nil)) } }
            )
        }
        .accessibilityHint("Edits the card")
    }

    private func cardLabel(_ card: MemoryCardListing) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MobileDesign.Spacing.xSmall))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.medium))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(wording(of: card))
                    .font(.body)
                    .lineLimit(3)
                Text(card.face.back.foldingMathSpans())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(MobileMemoryScreenCopy.statusLine(card.schedule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.screen.card.\(card.itemID)")
    }

    private func sourceTitle(_ sourceID: String) -> String? {
        let title = vm.sourcesByID[sourceID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// The card's first source, when this phone holds it under that id.
    private func openableSourceID(of card: MemoryCardListing) -> String? {
        guard let sourceID = card.sourceIDs.first, vm.sourcesByID[sourceID] != nil else { return nil }
        return sourceID
    }
}

// MARK: - The history grid

/// The run of review days (`MemoryReviewHistory`), the Mac's
/// `MemoryReviewHistoryGrid` on a phone: a square a day, a column a week,
/// half a year across (`MobileMemoryHistoryLayout`); the accent at a third
/// for a review started, two thirds past half the goal, solid once the goal
/// was met; today outlined; the rest of this week a hole. No number goes with
/// it. A square is too small to touch alone, so a tap anywhere on the grid
/// picks the nearest day and says it below — the Mac's tooltip — and a day
/// with an earlier review chat opens that chat from there. VoiceOver reads
/// every day that holds a review, and today, and opens a day's chat from its
/// square.
struct MobileMemoryHistoryGrid: View {
    let chatDays: Set<String>
    let answeredDays: Set<String>
    /// Every day's minutes against its goal (`MobileMemoryGoalModel.historyDays`).
    let dayProgress: [String: MemoryReviewDayProgress]
    let openChat: (MemoryReviewHistory.Day) -> Void

    @State private var width: Double = 0
    @State private var pickedKey: String?

    private typealias Layout = MobileMemoryHistoryLayout

    var body: some View {
        let weeks = Layout.weeks(width: width)
        let cell = Layout.cellSize(width: width, weeks: weeks)
        let grid = MemoryReviewHistory.grid(
            chatDays: chatDays,
            answeredDays: answeredDays,
            progress: dayProgress,
            weeks: weeks
        )
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            // No "Your reviews" caption over it: the grid under Start Review
            // says what it is.
            if width > 0, grid.reviewedDays > 0 {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                    monthRow(grid, cell: cell)
                        .padding(.leading, Layout.gutterWidth + Layout.gutterGap)
                    HStack(alignment: .top, spacing: Layout.gutterGap) {
                        weekdayGutter(cell: cell)
                        columns(grid, cell: cell)
                    }
                }
                if let day = picked(in: grid) {
                    pickedDayRow(day)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { proxy in
            Double(proxy.size.width)
        } action: { newWidth in
            width = newWidth
        }
        .sensoryFeedback(.selection, trigger: pickedKey)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.screen.history")
    }

    private func columns(_ grid: MemoryReviewHistory.Grid, cell: Double) -> some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            ForEach(grid.weeks) { week in
                VStack(spacing: Layout.spacing) {
                    ForEach(week.days) { day in
                        square(day, cell: cell)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            pick(at: tap.location, in: grid, cell: cell)
        })
    }

    /// The day under a tap: its column and row from where the tap landed,
    /// the gaps between squares going to the square before them.
    private func pick(at location: CGPoint, in grid: MemoryReviewHistory.Grid, cell: Double) {
        let stride = cell + Layout.spacing
        let column = Int((Double(location.x) / stride).rounded(.down))
        let row = Int((Double(location.y) / stride).rounded(.down))
        guard grid.weeks.indices.contains(column), grid.weeks[column].days.indices.contains(row) else { return }
        let day = grid.weeks[column].days[row]
        guard !day.isFuture else { return }
        pickedKey = pickedKey == day.key ? nil : day.key
    }

    private func picked(in grid: MemoryReviewHistory.Grid) -> MemoryReviewHistory.Day? {
        guard let pickedKey else { return nil }
        for week in grid.weeks {
            if let day = week.days.first(where: { $0.key == pickedKey }) { return day }
        }
        return nil
    }

    /// The picked day in words; with an earlier review chat behind it, a
    /// row that opens the chat.
    @ViewBuilder
    private func pickedDayRow(_ day: MemoryReviewHistory.Day) -> some View {
        let description = MobileMemoryScreenCopy.dayDescription(day)
        if day.hasChat {
            Button {
                openChat(day)
            } label: {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Text(description)
                        .foregroundStyle(.primary)
                    Spacer(minLength: MobileDesign.Spacing.small)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint("Opens that day's review chat")
            .accessibilityIdentifier("memory.screen.pickedDay")
        } else {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget, alignment: .leading)
                .accessibilityIdentifier("memory.screen.pickedDay")
        }
    }

    @ViewBuilder
    private func square(_ day: MemoryReviewHistory.Day, cell: Double) -> some View {
        if day.isFuture {
            Color.clear
                .frame(width: cell, height: cell)
                .accessibilityHidden(true)
        } else {
            let shape = RoundedRectangle(cornerRadius: cell * 0.23, style: .continuous)
            let description = MobileMemoryScreenCopy.dayDescription(day)
            shape
                .fill(Self.fill(for: day.level))
                .frame(width: cell, height: cell)
                .overlay {
                    if day.key == pickedKey {
                        shape.strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                    } else if day.isToday {
                        shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.2)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(description)
                .accessibilityAddTraits(day.hasChat ? .isButton : [])
                .accessibilityHint(day.hasChat ? "Opens that day's review chat" : "")
                .accessibilityAction {
                    if day.hasChat { openChat(day) }
                }
                .accessibilityHidden(day.level == .none && !day.isToday && !day.hasChat)
                .accessibilityIdentifier("memory.screen.day.\(day.key)")
        }
    }

    private static func fill(for level: MemoryReviewHistory.Level) -> Color {
        switch level {
        case .none: return Color(uiColor: .quaternarySystemFill)
        case .partial: return Color.accentColor.opacity(1.0 / 3.0)
        case .most: return Color.accentColor.opacity(2.0 / 3.0)
        case .met: return Color.accentColor
        }
    }

    private func monthRow(_ grid: MemoryReviewHistory.Grid, cell: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
            ForEach(grid.monthLabels) { label in
                Text(label.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: Double(label.column) * (cell + Layout.spacing))
            }
        }
        .accessibilityHidden(true)
    }

    /// Every other weekday's letter, as the Mac's gutter shows them.
    private func weekdayGutter(cell: Double) -> some View {
        VStack(alignment: .trailing, spacing: Layout.spacing) {
            ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .opacity(index.isMultiple(of: 2) ? 0 : 1)
                    .frame(height: cell)
            }
        }
        .frame(width: Layout.gutterWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private static var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }
}
