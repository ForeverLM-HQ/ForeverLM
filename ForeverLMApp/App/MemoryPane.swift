import SwiftUI

/// The Memory pane (docs/memory-design.md, "The Memory pane"): what the rail's
/// Memory row opens. Three sections:
///
/// - **Review**: today's cards in the scope ("6 due · 4 new"), the promise
///   starting makes in one line, **Start Review** — with **Practice**, the only thing
///   that gives the window over to the review (`startCardReview`) — and the
///   history grid. When the scope's new cards outside today's review are
///   waiting (kept today, or past the day's allowance), **Practice** deals
///   them (`startCardPractice`).
/// - **To Check**: the cards drafted from sources and not yet kept or
///   skipped, and the items from before cards, offered once — Keep, Edit,
///   Skip, a card at a time (`MemoryCardsToCheckView`).
/// - **All Cards**: every kept card in the scope, searched, by source or by
///   notebook; a click edits the card, and its menu starts it over or
///   retires it.
///
/// The sources and their cards are not a section: the Library's rows carry
/// each source's kept cards and its verdicts, and its No Cards pill lists
/// what still has none (`StudioViewModel+SourceCards.swift`; one list).
///
/// The scope is every notebook, or one, and the section and scope are the
/// window's (`StudioWindowState.memoryPaneScope`, `.memoryPaneSection`): the
/// rail's Memory row opens the pane on every notebook, a notebook's Studio
/// Cards tile on that notebook (`StudioViewModel.requestCardReview(scope:)`),
/// whose name then sits on the top line with the × back to every notebook.
/// The pane has no notebook menu: a review of some of the cards — a topic, a
/// source — is asked for in chat, which opens it (`practice_cards`).
/// Opening the pane writes nothing; its read runs off the main actor. It
/// claims no key: inside a notebook it sits beside the notebook's chat,
/// whose Return is the chat's.
struct MemoryPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    @State private var snapshot = MemoryCardReviewSnapshot.empty
    /// Each kept card's wording as asked, by item id.
    @State private var wordings: [String: String] = [:]
    /// The kept cards "Always ask in its own words" holds to, by item id.
    @State private var alwaysAsked: Set<String> = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var query = ""
    @State private var grouping: MemoryCardCatalog.Grouping = .source
    @State private var editing: MemoryCardListing?
    @State private var confirmingStartOver: MemoryCardListing?
    /// The All Cards groups folded away, by group id; this pane's only.
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredCard: String?

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .studioChromeLineHeader(opaque: true) {
                toolbar
                    .padding(.horizontal, 16)
                    .background(WindowDragBlocker())
            }
            .studioCenterTabCloseChrome(for: .memory)
            .onAppear { goalTracker.configure(storage: vm.storage) }
            .task(id: loadKey) { await load() }
            .onChange(of: vm.recordingScopeRevision) { _, _ in snapshot = .empty }
            .sheet(item: $editing) { card in
                MemoryCardEditorSheet(card: card, wording: wording(of: card)) { edit in
                    editing = nil
                    Task { await vm.applyMemoryCardEdit(edit, to: card) }
                } cancel: {
                    editing = nil
                }
            }
            .alert("Start this card over?", isPresented: Binding(
                get: { confirmingStartOver != nil },
                set: { if !$0 { confirmingStartOver = nil } }
            ), presenting: confirmingStartOver) { card in
                Button("Start Over") {
                    Task { await vm.startMemoryCardOver(card, revisedFace: nil) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It comes back as a new card, first asked tomorrow. Its answers so far stay with the old one.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory.pane")
    }

    /// The notebooks the pane counts and deals: the window's, or every
    /// notebook once that notebook is gone.
    private var scope: MemoryReviewScope { vm.memoryPaneScope(in: windowState) }

    private var section: MemoryPaneSection { windowState.memoryPaneSection }

    private var loadKey: String {
        "\(scopeTag)#\(vm.memoryCardRevision)#\(vm.recordingScopeRevision)#\(MemoryReviewGoal.dayKey(for: Date()))"
    }

    private func load() async {
        let scope = scope
        do {
            let read = try await vm.memoryCardReviewSnapshot(scope: scope, includesListings: true)
            guard !Task.isCancelled else { return }
            snapshot = read
            wordings = Self.wordings(of: read.cards)
            alwaysAsked = Self.alwaysAsked(read.cards)
            loadError = nil
        } catch {
            loadError = "The cards could not be read. \(error.localizedDescription)"
        }
        hasLoaded = true
    }

    // MARK: Toolbar

    /// The sections as the Space's pills — To Check with how many cards wait
    /// there, the state that asks for something — and, while the pane is
    /// narrowed to a notebook, that notebook.
    private var toolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                // While the window is writing a source's card, Write leads
                // the pills; any other ends the writing and opens itself.
                if windowState.cardWriting != nil {
                    SpaceScopePill(title: "Write", isSelected: true, count: nil) {}
                        .accessibilityIdentifier("memory.pane.section.write")
                }
                ForEach(MemoryPaneSection.allCases) { item in
                    SpaceScopePill(
                        title: item.title,
                        isSelected: windowState.cardWriting == nil && section == item,
                        count: pillCount(item)
                    ) {
                        vm.endCardWriting(in: windowState)
                        if windowState.memoryPaneSection != item { windowState.memoryPaneSection = item }
                    }
                    .accessibilityIdentifier("memory.pane.section.\(item.rawValue)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory.pane.section")

            Spacer(minLength: 8)

            if case .notebook = scope {
                narrowedNotebook
            }
        }
    }

    /// What waits in a section, drawn beside its name: the cards in To Check.
    private func pillCount(_ item: MemoryPaneSection) -> Int? {
        switch item {
        case .toCheck: return hasLoaded ? snapshot.toCheck.count : nil
        case .review, .allCards: return nil
        }
    }

    /// The notebook the pane was opened on — by its Cards tile, its Cards
    /// row, or the Reader's Cards count inside it — as a quiet word, and the
    /// × that widens the pane to every notebook. Over every notebook the top
    /// line holds nothing more: it has no notebook menu
    /// (product owner, 2026-10-13: "why even have this 'all notebooks' button
    /// for cards?"), and some of the cards are reviewed by asking in chat
    /// (`practice_cards`).
    private var narrowedNotebook: some View {
        let title = vm.memoryReviewScopeTitle(scope)
        return Button {
            if windowState.memoryPaneScope != .allNotebooks { windowState.memoryPaneScope = .allNotebooks }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .zoomedSystemFont(size: 12.5, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.06))
        .frame(maxWidth: 240, alignment: .trailing)
        .help("Show every notebook's cards")
        .accessibilityLabel("Show every notebook's cards")
        .accessibilityValue(title)
        .accessibilityIdentifier("memory.pane.scope")
    }

    private static let allNotebooksTag = "memory.scope.all"

    private var scopeTag: String {
        switch scope {
        case .allNotebooks: return Self.allNotebooksTag
        case .notebook(let id): return id
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let writing = windowState.cardWriting {
            // A new source is a new blank card.
            MemoryCardWritingView(session: writing, windowState: windowState)
                .id(writing.sourceID)
        } else {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .review: reviewSection
        case .toCheck: toCheckSection
        case .allCards: allCardsSection
        }
    }

    // MARK: Review

    /// Today's cards (docs/memory-design.md, "How a card looks") are drawn as the deck the review deals: one card with how many
    /// there are, the edges of the rest under it, the promise in a line, and
    /// one dark pill — the review's own Start Review — with Practice a quiet
    /// word beside it. The history grid sits under them.
    private var reviewSection: some View {
        let counts = snapshot.counts
        let state = goalTracker.state
        return ScrollView {
            VStack(spacing: 0) {
                todayDeck(counts: counts, state: state)
                    .padding(.bottom, MemoryDeckEdges.depth)

                if hasLoaded, Self.showsPromise(state: state, counts: counts) {
                    Text(Self.promise(state: state, budgetMinutes: MemoryReviewBudget.minutes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                        .padding(.top, 22)
                        .accessibilityIdentifier("memory.pane.promise")
                }

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.disabled)
                        .padding(.top, 14)
                }

                let offersPractice = counts.practice > 0
                let primaryTitle = Self.primaryTitle(state: state, counts: counts)
                if primaryTitle != nil || offersPractice {
                    VStack(spacing: 8) {
                        // No Return: inside a notebook the pane sits beside the
                        // chat, whose composer Return belongs to.
                        if let primaryTitle {
                            MemoryReviewButton(title: primaryTitle, kind: .primary, minWidth: 200) {
                                vm.inWindow(windowState) { vm.startCardReview(scope: scope) }
                            }
                            .accessibilityIdentifier("memory.pane.start")
                        }
                        if offersPractice {
                            MemoryReviewButton(
                                title: counts.practice == 1 ? "Practice 1 New Card" : "Practice \(counts.practice) New Cards",
                                kind: .quiet
                            ) {
                                vm.inWindow(windowState) { vm.startCardPractice(scope: scope) }
                            }
                            .help("Cards kept today, or past today's new cards, asked now")
                            .accessibilityIdentifier("memory.pane.practice")
                        }
                    }
                    .padding(.top, 20)
                }

                // Screen record mode (admin only) keeps the learner's own
                // review history off screen: the grid is months of their days.
                if !ScreenRecordMode.isEffective {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        MemoryReviewHistoryGrid(
                            earlierReviews: MemoryPane.earlierReviews(
                                in: vm.reviewSessionGroups(for: vm.pinnedNotebooks).memory
                            ),
                            dayProgress: goalTracker.historyDays,
                            answeredDays: goalTracker.answeredDays
                        ) { sessionID in
                            vm.inWindow(windowState) { vm.requestResumeReviewSession(sessionID) }
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 44)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("memory.pane.review")
    }

    /// Today's cards as a card on the deck: how many, "cards today", and
    /// "6 due · 4 new" under it; with none, what the day is instead.
    private func todayDeck(counts: MemoryCardDayCounts, state: MemoryReviewCommitment.State) -> some View {
        let today = hasLoaded ? counts.today : 0
        return VStack(spacing: 6) {
            if !hasLoaded {
                Color.clear.frame(height: 1)
            } else if today > 0 {
                Text("\(today)")
                    .font(.system(size: 56, weight: .regular, design: .serif))
                    .monospacedDigit()
                Text(today == 1 ? "card today" : "cards today")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                if let line = counts.todayLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, 2)
                }
            } else if case .done = state {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Today's review is done")
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .padding(.top, 4)
            } else {
                Text("Nothing due today")
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .textSelection(.disabled)
        .padding(.horizontal, 24)
        .frame(width: 300, height: 184)
        .memoryCardSurface()
        .background(alignment: .bottom) {
            MemoryDeckEdges(remaining: today - 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.pane.counts")
    }

    /// Whether the promise line shows under the deck: while Start Review or
    /// Keep Going is there to say what it commits to, and on a day ended
    /// early, which it says; never a second "done" under a done deck.
    static func showsPromise(state: MemoryReviewCommitment.State, counts: MemoryCardDayCounts) -> Bool {
        switch state {
        case .open, .done: return counts.today > 0
        case .ended: return true
        }
    }

    /// The promise above Start Review, by state, in one short line. Pure, so
    /// the words cannot drift from the rule: starting gives the window to
    /// the day's minutes, and leaving before the cards are done ends the
    /// day's session. One line, not three sentences
    /// (product owner, 2026-10-06: "cleaner and fewer buttons and bells and whistles"): the
    /// minutes and what leaving early does, which Start Review cannot say.
    static func promise(state: MemoryReviewCommitment.State, budgetMinutes: Int) -> String {
        let budget = MemoryReviewBudget.label(budgetMinutes)
        switch state {
        case .open:
            return "Up to \(budget). Leaving early ends today's review."
        case .ended(let seconds):
            let minutes = Int((seconds / 60).rounded())
            let after = minutes >= 1 ? " after \(minutes == 1 ? "1 minute" : "\(minutes) minutes")" : ""
            return "Today's review ended\(after)."
        case .done:
            return "Today's review is done."
        }
    }

    /// The primary button, by state: Start Review while the day is open and
    /// a card waits, Keep Going on a done or ended day with cards left —
    /// cards waiting always have a button — nothing with no
    /// card waiting.
    static func primaryTitle(state: MemoryReviewCommitment.State, counts: MemoryCardDayCounts) -> String? {
        guard counts.today > 0 else { return nil }
        switch state {
        case .open: return "Start Review"
        case .done, .ended: return "Keep Going"
        }
    }

    /// The days the grid can open: every day's review chat from before cards
    /// but today's, newest first. `sessions` is the rail's Memory group — the
    /// learner's own review chats in the current library — and a session
    /// whose id names no day sorts after the dated ones.
    static func earlierReviews(
        in sessions: [ReviewSessionRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ReviewSessionRecord] {
        let todayID = MemoryReviewSession.sessionID(for: now, calendar: calendar)
        return sessions
            .filter { MemoryReviewSession.isMemorySession($0.id) && $0.id != todayID }
            .sorted { lhs, rhs in
                let lhsDay = MemoryReviewSession.date(fromSessionID: lhs.id, calendar: calendar) ?? .distantPast
                let rhsDay = MemoryReviewSession.date(fromSessionID: rhs.id, calendar: calendar) ?? .distantPast
                return lhsDay > rhsDay
            }
    }

    // MARK: To check

    private var toCheckSection: some View {
        MemoryCardsToCheckView(cards: snapshot.toCheck, hasLoaded: hasLoaded)
            // Another scope is another sitting: its count starts over.
            .id(scopeTag)
    }

    // MARK: All cards

    /// The column All Cards reads in, centred in a wide pane.
    private static let columnMaxWidth: CGFloat = 680

    /// The list a row at a time — a group's header, then its cards — flat,
    /// so the lazy stack builds each card on its own. A card in two
    /// notebooks is listed under both, so its row is keyed by its group.
    private enum CatalogRow: Identifiable {
        case group(MemoryCardCatalog.Group, isFirst: Bool)
        case card(MemoryCardListing, groupID: String)

        var id: String {
            switch self {
            case .group(let group, _): return "group:" + group.id
            case .card(let card, let groupID): return "card:" + groupID + ":" + card.itemID
            }
        }
    }

    private static func catalogRows(_ groups: [MemoryCardCatalog.Group], collapsed: Set<String>) -> [CatalogRow] {
        groups.enumerated().flatMap { index, group in
            [CatalogRow.group(group, isFirst: index == 0)]
                + (collapsed.contains(group.id) ? [] : group.cards.map { CatalogRow.card($0, groupID: group.id) })
        }
    }

    /// The list reads like To Check (product owner, 2026-10-10, at a
    /// full-width list with "Due" on every row: "this looks bad and should
    /// be redesigned"): a centred column under a one-line count, each source headed
    /// by its cover and how many of its cards are due, folding away on a
    /// click, and each card its front in the review's serif over its back.
    /// When a card is next asked shows under the pointer; the group says
    /// how many are due.
    private var allCardsSection: some View {
        // A card deleted here leaves the list while its Undo waits.
        let listed = snapshot.cards.filter {
            !vm.hasPendingDeletion(forDeletionKey: StudioViewModel.memoryCardRemovalKey($0.itemID))
        }
        let searched = MemoryCardCatalog.search(
            listed,
            query: query,
            wording: wording(of:),
            sourceTitle: sourceTitle(_:)
        )
        let groups = MemoryCardCatalog.grouped(
            searched,
            by: grouping,
            sourceTitle: sourceTitle(_:),
            book: bookTitle(_:),
            notebooks: grouping == .notebook ? vm.memoryCardScopes(for: vm.notebooks) : []
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                allCardsHeader
                    .padding(.bottom, 6)
                if groups.isEmpty {
                    Text(hasLoaded ? (snapshot.cards.isEmpty ? "No kept cards" : "No card matches") : " ")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Self.catalogRows(groups, collapsed: collapsedGroups)) { row in
                    switch row {
                    case .group(let group, let isFirst):
                        groupHeader(group)
                            .padding(.top, isFirst ? 16 : 26)
                            .padding(.bottom, 12)
                    case .card(let card, _):
                        cardRow(card)
                            .padding(.bottom, 14)
                    }
                }
            }
            .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("memory.pane.cards")
    }

    /// The count, then search and the grouping on one quiet line.
    private var allCardsHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasLoaded ? Self.cardCount(snapshot.cards.count) : " ")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let due = Self.dueDetail(snapshot.cards) {
                    Text(due)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .textSelection(.disabled)
            .accessibilityIdentifier("memory.pane.cards.summary")

            HStack(spacing: 12) {
                // The Space's search (`SpaceSearchField`), as over every list.
                SpaceSearchField(text: $query, prompt: "Search cards", identifier: "memory.pane.search")
                    .frame(maxWidth: 360)

                Spacer(minLength: 0)

                Menu {
                    Picker("Group", selection: $grouping) {
                        ForEach(MemoryCardCatalog.Grouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(grouping.title)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("List the cards by source or by notebook")
                .accessibilityIdentifier("memory.pane.grouping")
            }
        }
    }

    /// A source's cover and title, or a notebook's title, with how many of
    /// its cards there are and how many are due; a click folds it.
    private func groupHeader(_ group: MemoryCardCatalog.Group) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)
        let sourceID = grouping == .source && group.id != MemoryCardCatalog.unfiledID ? group.id : nil
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isCollapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
            }
        } label: {
            HStack(spacing: 10) {
                if let sourceID {
                    groupThumbnail(sourceID)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([group.book, Self.groupDetail(group.cards)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .textSelection(.disabled)
        .help(isCollapsed ? "Show these cards" : "Fold these cards away")
        .contextMenu {
            if let sourceID {
                Button("Open Source") {
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: .memory) }
                }
                OtherWindowSourceMenuItem(sourceID: sourceID)
            }
        }
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        .accessibilityIdentifier("memory.pane.cards.group.\(group.id)")
    }

    /// The source's picture as every source list draws it, or its kind's
    /// symbol when the library no longer holds it.
    @ViewBuilder
    private func groupThumbnail(_ sourceID: String) -> some View {
        if let article = vm.articlesById[vm.canonicalSourceID(sourceID)] {
            let bookCoverPath = article.sourceType == .book
                ? article.parentGroup.flatMap { vm.bookCoverPaths[$0] }
                : nil
            SourceThumbnail(source: article, size: 30, bookCoverPath: bookCoverPath)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
                .accessibilityHidden(true)
        }
    }

    private func cardRow(_ card: MemoryCardListing) -> some View {
        let isHovered = hoveredCard == card.itemID
        return Button {
            editing = card
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wording(of: card))
                        .font(.system(size: 14.5, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.face.back.foldingMathSpans())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Self.statusLine(card.schedule))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .opacity(isHovered ? 1 : 0)
            }
            .textSelection(.disabled)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -7))
        .onHover { inside in
            if inside { hoveredCard = card.itemID } else if hoveredCard == card.itemID { hoveredCard = nil }
        }
        .contextMenu {
            Button("Edit Card…") { editing = card }
            Button("Start Over…") { confirmingStartOver = card }
            Button(alwaysAsked.contains(card.itemID) ? "Let Its Wording Vary" : "Always Ask in Its Own Words") {
                vm.setMemoryCardAlwaysAsk(!alwaysAsked.contains(card.itemID), for: card)
            }
            .help("A card remembered twice is asked in other words, same answer; this keeps it in its own")
            if let sourceID = card.sourceIDs.first {
                Divider()
                Button("Open Source") {
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: .memory) }
                }
                OtherWindowSourceMenuItem(sourceID: sourceID)
            }
            Divider()
            Button("Delete Card", role: .destructive) { vm.deleteMemoryCardFromList(card) }
                .help("Never asked again; Undo waits at the foot of the window")
        }
        .accessibilityValue(Self.statusLine(card.schedule))
        .accessibilityIdentifier("memory.pane.card.\(card.itemID)")
    }

    /// "1 card", "40 cards".
    static func cardCount(_ count: Int) -> String {
        count == 1 ? "1 card" : "\(count) cards"
    }

    /// "28 due · 3 new", leaving out a zero; nil when none is either.
    static func dueDetail(_ cards: [MemoryCardListing], now: Date = Date()) -> String? {
        let new = cards.filter(\.schedule.isNew).count
        let due = cards.filter { !$0.schedule.isNew && $0.schedule.dueAt <= now }.count
        let parts = [due > 0 ? "\(due) due" : nil, new > 0 ? "\(new) new" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "6 cards · 4 due", or "6 cards" when none is due or new.
    static func groupDetail(_ cards: [MemoryCardListing], now: Date = Date()) -> String {
        [cardCount(cards.count), dueDetail(cards, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "New", "Due", or the day a card is next asked.
    static func statusLine(_ schedule: MemorySchedule, now: Date = Date(), calendar: Calendar = .current) -> String {
        if schedule.isNew { return "New" }
        if schedule.dueAt <= now { return "Due" }
        if calendar.isDateInTomorrow(schedule.dueAt) { return "Tomorrow" }
        return schedule.dueAt.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The card as it is asked: the learner's rewording when they made one,
    /// read from the state rows once per load.
    private func wording(of card: MemoryCardListing) -> String {
        wordings[card.itemID] ?? card.face.front
    }

    private static func alwaysAsked(_ cards: [MemoryCardListing]) -> Set<String> {
        Set(cards.compactMap { card in
            let deckID = card.face.deckID ?? card.sourceIDs.first.map(MemoryCard.draftDeckID(sourceID:))
            let state = deckID.flatMap { MemoryCardStateStore.state(cardID: card.face.cardID, deckID: $0) }
            return state?.alwaysAsk == true ? card.itemID : nil
        })
    }

    private static func wordings(of cards: [MemoryCardListing]) -> [String: String] {
        var wordings: [String: String] = [:]
        for card in cards {
            let deckID = card.face.deckID ?? card.sourceIDs.first.map(MemoryCard.draftDeckID(sourceID:))
            let state = deckID.flatMap { MemoryCardStateStore.state(cardID: card.face.cardID, deckID: $0) }
            wordings[card.itemID] = card.face.wording(state: state)
        }
        return wordings
    }

    private func sourceTitle(_ sourceID: String) -> String? {
        vm.articlesById[vm.canonicalSourceID(sourceID)]?.title
    }

    /// The book a chapter belongs to, by its title; nil for any other source.
    private func bookTitle(_ sourceID: String) -> String? {
        guard let article = vm.articlesById[vm.canonicalSourceID(sourceID)],
              article.sourceType == .book,
              let group = article.parentGroup else { return nil }
        return vm.bookDisplayName(group)
    }
}

// MARK: - Editing a card

/// A kept card's front, back and why. A new front alone rewords the card
/// (its state row); a new back or why starts it over, which the sheet says
/// before it saves (docs/memory-design.md, "Cards: identity and Keep").
struct MemoryCardEditorSheet: View {
    let card: MemoryCardListing
    let wording: String
    let save: (MemoryCardEdit) -> Void
    let cancel: () -> Void

    @State private var front: String
    @State private var back: String
    @State private var why: String
    @State private var confirmingStartOver = false

    init(card: MemoryCardListing, wording: String, save: @escaping (MemoryCardEdit) -> Void, cancel: @escaping () -> Void) {
        self.card = card
        self.wording = wording
        self.save = save
        self.cancel = cancel
        _front = State(initialValue: wording)
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

    private var startsOver: Bool {
        edit.back != card.face.back || edit.why != card.face.why
    }

    var body: some View {
        MemoryCardEditorForm(
            front: $front,
            back: $back,
            why: $why,
            frontImages: card.face.frontImages,
            backImages: card.face.backImages,
            primaryTitle: "Save",
            canSave: !edit.front.isEmpty && !edit.back.isEmpty,
            cancel: cancel
        ) {
            if startsOver {
                confirmingStartOver = true
            } else {
                save(edit)
            }
        }
        .alert("Start this card over?", isPresented: $confirmingStartOver) {
            Button("Start Over") { save(edit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new answer makes a new card, first asked tomorrow. Its answers so far stay with the old one.")
        }
        .accessibilityIdentifier("memory.pane.editor")
    }
}

// MARK: - The history grid

/// The run of review days: a square a day, a column a week, the darkest
/// squares the days whose goal was met (`MemoryReviewHistory`). A square with a
/// review chat behind it — a day that was reviewed as a chat — opens that chat; a card
/// day is coloured by its minutes and opens nothing.
struct MemoryReviewHistoryGrid: View {
    var earlierReviews: [ReviewSessionRecord]
    /// Every day's minutes against its goal, from `MemoryReviewEngagementTracker`.
    var dayProgress: [String: MemoryReviewDayProgress]
    /// The days whose chat the learner wrote in, from the same tracker.
    var answeredDays: Set<String>
    var openReview: (String) -> Void

    private static let cellSize: CGFloat = 11
    private static let cellSpacing: CGFloat = 3
    private static let columnStride = cellSize + cellSpacing
    private static let gutterWidth: CGFloat = 12

    private var history: MemoryReviewHistory.Grid {
        MemoryReviewHistory.grid(
            chatDays: Set(earlierReviews.compactMap { MemoryReviewSession.dayKey(fromSessionID: $0.id) }),
            answeredDays: answeredDays,
            progress: dayProgress
        )
    }

    var body: some View {
        let history = history
        if history.reviewedDays > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your reviews")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                VStack(alignment: .leading, spacing: 4) {
                    monthRow(history)
                        .padding(.leading, Self.gutterWidth + 6)
                    HStack(alignment: .top, spacing: 6) {
                        weekdayGutter
                        HStack(alignment: .top, spacing: Self.cellSpacing) {
                            ForEach(history.weeks) { week in
                                VStack(spacing: Self.cellSpacing) {
                                    ForEach(week.days) { day in
                                        daySquare(day)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory.pane.history")
        }
    }

    private func monthRow(_ history: MemoryReviewHistory.Grid) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 10)
            ForEach(history.monthLabels) { label in
                Text(label.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .textSelection(.disabled)
                    .offset(x: CGFloat(label.column) * Self.columnStride)
            }
        }
        .accessibilityHidden(true)
    }

    private var weekdayGutter: some View {
        VStack(alignment: .trailing, spacing: Self.cellSpacing) {
            ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .opacity(index.isMultiple(of: 2) ? 0 : 1)
                    .frame(height: Self.cellSize)
            }
        }
        .frame(width: Self.gutterWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func daySquare(_ day: MemoryReviewHistory.Day) -> some View {
        if day.isFuture {
            Color.clear
                .frame(width: Self.cellSize, height: Self.cellSize)
        } else if day.hasChat {
            Button {
                openReview(MemoryReviewSession.idPrefix + day.key)
            } label: {
                square(day)
            }
            .buttonStyle(.hoverWash(cornerRadius: 4, inset: -2, opacity: 0.14))
            .opensInOtherWindow(.chat(MemoryReviewSession.idPrefix + day.key))
            .help(Self.dayDescription(day))
            .accessibilityLabel(Self.dayDescription(day))
            .accessibilityIdentifier("memory.pane.day.\(day.key)")
        } else {
            square(day)
                .help(Self.dayDescription(day))
                .accessibilityHidden(!day.isToday)
                .accessibilityLabel(Self.dayDescription(day))
        }
    }

    private func square(_ day: MemoryReviewHistory.Day) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        return shape
            .fill(Self.fill(for: day.level))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay {
                if day.isToday {
                    shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.2)
                }
            }
    }

    private static func fill(for level: MemoryReviewHistory.Level) -> Color {
        switch level {
        case .none: return Color(nsColor: .quaternarySystemFill)
        case .partial: return Color.accentColor.opacity(0.3)
        case .most: return Color.accentColor.opacity(0.6)
        case .met: return Color.accentColor
        }
    }

    /// The tooltip, and what VoiceOver reads: the date, and what happened on it.
    static func dayDescription(_ day: MemoryReviewHistory.Day) -> String {
        let date = MemoryReviewSession.title(for: day.date)
        let today = day.isToday ? " · today" : ""
        guard day.level != .none else { return date + today }
        let minutes = Int((day.activeSeconds / 60).rounded())
        return minutes >= 1 ? "\(date) · \(minutes) min\(today)" : "\(date) · review\(today)"
    }

    private static var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }
}
