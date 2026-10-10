import SwiftUI

// Memory on the iPhone and iPad (docs/memory-design.md, "The Memory screen
// on the iPhone"): the Mac's Memory pane (`App/MemoryPane.swift`) over every
// notebook, and Home's Memory strip, the Mac's `NotebooksHomeMemoryStripView`.
// Review says today's cards ("6 due · 4 new"), starts the card review (Start
// Review, Keep Going, Practice N New Cards) and draws the history grid; To
// Check goes through the cards drafted from sources (Keep, Edit, Skip,
// `MobileCardsToCheckList`); All Cards lists every kept card, searched, by
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
    /// last card never pulls it away (2026-10-06: a section with nothing in
    /// it is not drawn; a notebook's Cards row still opens its own).
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

    private var reviewSection: some View {
        let state = MobileMemoryScreenCopy.state(goal: goal.snapshot)
        return ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.xLarge) {
                sectionPicker
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    Text(knowsCards ? MobileMemoryScreenCopy.countsLine(counts) : " ")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityIdentifier("memory.screen.counts")
                    if let promise = MobileMemoryScreenCopy.promise(state: state) {
                        Text(promise)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("memory.screen.promise")
                    }
                }
                actions(state: state)
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

    /// Start Review or Keep Going, and Practice N New Cards, side by side
    /// when they fit, the Mac's pane's buttons. Each pushes the card review
    /// over every notebook, whose title changes the scope.
    @ViewBuilder
    private func actions(state: MemoryReviewCommitment.State) -> some View {
        let primary = knowsCards ? MobileMemoryScreenCopy.primaryTitle(state: state, counts: counts) : nil
        let practices = knowsCards && MemoryReviewCommitment.canStart(state) && counts.practice > 0
        if primary != nil || practices {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MobileDesign.Spacing.medium) {
                    actionButtons(primary: primary, practices: practices)
                }
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    actionButtons(primary: primary, practices: practices)
                }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func actionButtons(primary: String?, practices: Bool) -> some View {
        if let primary {
            Button(primary) {
                open(.cardReview(.allNotebooks))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("memory.screen.start")
        }
        if practices {
            Button(MobileCardReviewCopy.practiceNewCards(counts.practice)) {
                open(.cardPractice(.allNotebooks))
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Cards kept today, or past today's new cards, asked now")
            .accessibilityIdentifier("memory.screen.practice")
        }
    }

    // MARK: To check

    private var toCheckSection: some View {
        MobileCardsToCheckList(scope: .allNotebooks) { sourceID in
            open(.source(sourceID, notebookID: nil))
        } header: {
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
                Text(card.face.back)
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
            // No "Your reviews" caption over it since 2026-10-06: the grid
            // under Start Review says what it is.
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

// MARK: - Home's strip

/// Home's Memory strip, the Mac's `NotebooksHomeMemoryStripView`: the Memory
/// glyph in the accent, "Memory", what waits in one line ("6 due · 4 new ·
/// 9 to check"), and a chevron; a tap opens the Memory screen, whose Start
/// Review starts. Home draws it only while something waits (2026-10-06).
/// No badge, streak or minutes trail it. Stacked when the type is too large
/// for one line.
struct MobileMemoryStrip: View {
    let line: String
    let action: () -> Void

    private static let radius: CGFloat = 12

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileDesign.Spacing.medium) {
                Image(systemName: MemoryReviewSession.sidebarIcon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        title
                        detail
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        detail
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.vertical, MobileDesign.Spacing.medium)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Memory")
        .accessibilityValue(line)
        .accessibilityHint("Review today's cards from every notebook")
        .accessibilityIdentifier("home.memory")
    }

    private var title: some View {
        Text("Memory")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var detail: some View {
        Text(line)
            .font(.body)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}
