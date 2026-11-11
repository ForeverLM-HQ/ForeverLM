import SwiftUI

/// Today's memory review chat on the phone, from before cards: the same chat
/// the Mac's Memory row opened, read from and written to the same synced
/// record — reached since the phone's card review only by the card review's
/// Continue Today's Review Chat — dealt as a deck of
/// cards — one exchange a card, swiped through like the walkthrough's deck —
/// or, from the header's switch, as the conversation underneath. The cards,
/// the composer, and the two chips under a graded reply are the whole surface
/// (docs/memory-design.md "Cards").
///
/// A review planned by topic deals a card per topic instead: its head names
/// the topic and its kind, the opening question is set large, the grade draws
/// a ledger of the topic's ideas under the tutor's reply, and the header's
/// source count gives way to a stepper over the topics (docs/memory-design.md
/// "Review by topic").
struct MobileMemoryReviewView: View {
    @ObservedObject var viewModel: MobileMemoryReviewViewModel

    @StateObject private var dictation = MobileComposerDictation()
    @ObservedObject private var goal = MobileMemoryGoalModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isComposerFocused: Bool
    /// Cards or conversation, remembered on this phone. The Mac keeps its
    /// own under the same key.
    @AppStorage(Prefs.Memory.reviewLayout, default: "cards") private var layoutRaw: String
    /// The card swiped back to; nil for the newest, the one being answered.
    @State private var selectedCard: Int?

    private var showsCards: Bool { layoutRaw != "conversation" }

    var body: some View {
        VStack(spacing: 0) {
            if showsCards {
                deck
            } else {
                transcript
            }
            composer
        }
        .background {
            if showsCards {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
        }
        .task { await viewModel.open() }
        // The day's goal clock runs while this screen is up and the app is in
        // front; typing, sending, a chip, a scroll, or a reply streaming in
        // keeps it running.
        .onAppear {
            goal.setSceneActive(scenePhase == .active)
            goal.present()
        }
        .onDisappear {
            viewModel.finish()
            goal.dismiss()
        }
        .onChange(of: scenePhase) { _, phase in goal.setSceneActive(phase == .active) }
        .onChange(of: viewModel.draft) { _, _ in goal.noteActivity() }
        .onChange(of: viewModel.isResponding) { _, responding in goal.setTutorResponding(responding) }
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in goal.noteActivity() })
        .simultaneousGesture(TapGesture().onEnded { goal.noteActivity() })
        .overlay {
            if let celebration = goal.celebration {
                MemoryGoalCelebrationView(goalMinutes: celebration.goalMinutes, streak: celebration.streak) {
                    goal.acknowledgeCelebration(celebration.id)
                }
                .transition(.opacity)
                .accessibilityIdentifier("memory.goalCelebration")
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    header
                        .padding(.bottom, MobileDesign.Spacing.xSmall)
                    // A reply's row is empty until its first words; the
                    // working line stands in for it until then.
                    ForEach(viewModel.messages.filter { !($0.isStreaming && $0.content.isEmpty) }) { message in
                        MobileMemoryReviewMessageRow(message: message)
                            .id(message.id)
                    }
                    if viewModel.showsWorkingLine {
                        workingLine
                            .id(Self.workingLineID)
                    }
                    if viewModel.awaitsSteer, !viewModel.isResponding {
                        steerChips
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("memory.error")
                    }
                }
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.medium)
            }
            .onChange(of: viewModel.showsWorkingLine) { _, shows in
                guard shows else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.workingLineID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: MemoryReviewSession.sidebarIcon)
                .foregroundStyle(Color.accentColor)
            Text(viewModel.title)
                .font(.headline)
            Spacer(minLength: 0)
            if viewModel.isTopicReview {
                topicStepper
            } else if !viewModel.sourceStatusLine.isEmpty {
                Text(viewModel.sourceStatusLine)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory.progress")
            }
            layoutSwitch
        }
        .accessibilityElement(children: .contain)
    }

    /// Cards or the conversation under them, one tap each way.
    private var layoutSwitch: some View {
        Button {
            selectedCard = nil
            withAnimation(.easeOut(duration: 0.2)) {
                layoutRaw = showsCards ? "conversation" : "cards"
            }
        } label: {
            Image(systemName: showsCards ? "text.bubble" : "rectangle.stack")
                .font(.body.weight(.semibold))
                .frame(
                    width: MobileDesign.Metrics.minimumTouchTarget,
                    height: MobileDesign.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(showsCards ? "Show as Conversation" : "Show as Cards")
        .accessibilityIdentifier("memory.layout")
    }

    /// The topics as a row of dots: finished ones filled, the current one
    /// accented, the rest waiting. What the source count is in a review
    /// planned source by source.
    private var topicStepper: some View {
        let progress = viewModel.topicProgress
        let current = progress.firstIndex(of: .current).map { $0 + 1 }
        return HStack(spacing: MobileDesign.Spacing.xSmall) {
            ForEach(progress.indices, id: \.self) { index in
                Circle()
                    .fill(Self.stepColor(progress[index]))
                    .frame(width: 8, height: 8)
                    .overlay {
                        if progress[index] == .current {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).padding(-3)
                        }
                    }
            }
        }
        .padding(.trailing, MobileDesign.Spacing.xSmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.map { "Topic \($0) of \(progress.count)" } ?? "\(progress.count) topics")
        .accessibilityIdentifier("memory.topics")
    }

    private static func stepColor(_ progress: MemoryReviewTopicProgress) -> Color {
        switch progress {
        case .waiting: Color.secondary.opacity(0.25)
        case .current: Color.accentColor
        case .finished: Color.accentColor.opacity(0.5)
        }
    }

    // MARK: - Cards

    /// The review as a deck: a page a card, swiped sideways, the newest in
    /// front. Sending an answer deals its card at once and brings the deck to
    /// it; an older card is a record, with no chips and no working line. A
    /// review planned by topic deals a card per topic.
    private var deck: some View {
        let turns = viewModel.messages.map(Self.dealingTurn)
        let cards = viewModel.isTopicReview
            ? MemoryReviewCardDealing.topicCards(turns)
            : MemoryReviewCardDealing.cards(turns)
        let current = MemoryReviewCardDealing.resolvedIndex(selectedCard, count: cards.count)
        let position = Binding<Int>(
            get: { current ?? 0 },
            set: { selectedCard = $0 >= cards.count - 1 ? nil : $0 }
        )
        return VStack(spacing: 0) {
            header
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.top, MobileDesign.Spacing.small)
            if cards.isEmpty {
                // Opening or planning: the card to come is the working line.
                card(messages: [], sourceID: nil, ordinal: nil, isNewest: true)
            } else {
                TabView(selection: position) {
                    ForEach(cards.indices, id: \.self) { index in
                        card(
                            messages: Array(viewModel.messages[cards[index].range]),
                            sourceID: cards[index].sourceID,
                            ordinal: (index + 1, cards.count),
                            isNewest: index == cards.count - 1
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                deckControls(count: cards.count, current: current ?? 0)
            }
        }
        .onChange(of: cards.count) { _, _ in selectedCard = nil }
    }

    /// The phone keeps a tutor's turn line on its message rather than as a
    /// row of its own, so a reply carries where it turns to; the dealing
    /// reads it the same as a heading row.
    private static func dealingTurn(_ message: MobileMemoryReviewMessage) -> MemoryReviewCardDealing.Turn {
        switch message.role {
        case .learner: .answer
        case .tutor: .reply(turnsTo: message.sourceID)
        }
    }

    private func card(
        messages: [MobileMemoryReviewMessage],
        sourceID: String?,
        ordinal: (Int, Int)?,
        isNewest: Bool
    ) -> some View {
        let title = sourceID.flatMap(viewModel.sourceTitle) ?? "Today's review"
        let topic = viewModel.topic(sourceID)
        let ledger = viewModel.ledgerRows(forTopic: sourceID)
        // On a topic card the first thing the tutor says is the opening
        // question, set large so it is the one thing that reads as text to
        // answer.
        let openingID = topic == nil ? nil : messages.first { $0.role == .tutor }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .kerning(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(2)
                            .textSelection(.disabled)
                            .accessibilityIdentifier("memory.card.source")
                        if let topic {
                            Text(topic.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.disabled)
                                .accessibilityIdentifier("memory.card.kind")
                        }
                        Spacer(minLength: MobileDesign.Spacing.small)
                        if let ordinal {
                            Text("\(ordinal.0) / \(ordinal.1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .textSelection(.disabled)
                                .accessibilityLabel("Card \(ordinal.0) of \(ordinal.1)")
                        }
                    }
                    ForEach(messages.filter { !($0.isStreaming && $0.content.isEmpty) }) { message in
                        MobileMemoryReviewMessageRow(message: message, isOpening: message.id == openingID)
                            .id(message.id)
                    }
                    if !ledger.isEmpty {
                        ledgerRows(ledger)
                    }
                    if isNewest {
                        if viewModel.showsWorkingLine {
                            workingLine
                                .id(Self.workingLineID)
                        }
                        if viewModel.awaitsSteer, !viewModel.isResponding {
                            steerChips
                        }
                        if viewModel.offersDontRemember {
                            dontRememberButton
                        }
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("memory.error")
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.cardEndID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MobileDesign.Spacing.xLarge)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: isNewest ? messages.last?.content : nil) { _, _ in
                // The reply streaming onto the newest card keeps its end in view.
                guard isNewest else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.cardEndID, anchor: .bottom)
                }
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: MobileDesign.Radius.composer, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: MobileDesign.Radius.composer, style: .continuous))
        .shadow(color: MobileDesign.elevatedShadow, radius: 12, y: 4)
        .frame(maxWidth: MobileDesign.Metrics.readableContentWidth)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.card")
    }

    /// Back and Next under the deck, and the way to the card being answered
    /// while an older one is up. Swiping does the same.
    private func deckControls(count: Int, current: Int) -> some View {
        let onNewest = current >= count - 1
        return HStack {
            Button {
                withAnimation { selectedCard = MemoryReviewCardDealing.step(selectedCard, by: -1, count: count) }
            } label: {
                Label("Previous card", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .disabled(current == 0)
            .accessibilityIdentifier("memory.card.back")

            Spacer()

            if !onNewest {
                Button {
                    withAnimation { selectedCard = nil }
                } label: {
                    Label("Current card", systemImage: "arrow.uturn.forward")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("memory.card.current")

                Spacer()
            }

            Button {
                withAnimation { selectedCard = MemoryReviewCardDealing.step(selectedCard, by: 1, count: count) }
            } label: {
                Label("Next card", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(
                        width: MobileDesign.Metrics.minimumTouchTarget,
                        height: MobileDesign.Metrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .disabled(onNewest)
            .accessibilityIdentifier("memory.card.next")
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
    }

    private static let workingLineID = "memory.workingLine"
    private static let cardEndID = "memory.cardEnd"

    /// A topic's ledger under the graded reply: a row per cued idea in the
    /// topic's order. What came back shows its statement; what did not is
    /// veiled, "Not yet" over the source it came from, until a failed probe
    /// reveals it.
    private func ledgerRows(_ rows: [MemoryReviewLedgerRow]) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ForEach(rows, id: \.ideaID) { row in
                HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                    Image(systemName: Self.ledgerGlyph(row.status))
                        .font(.subheadline)
                        .foregroundStyle(row.status == .missing ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.statement ?? "Not yet")
                            .font(row.isVeiled ? .subheadline.weight(.medium) : .subheadline)
                            .foregroundStyle(row.isVeiled ? .secondary : .primary)
                        if let sourceID = row.sourceID, let source = viewModel.sourceTitle(sourceID) {
                            Text(source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.ledgerLabel(row.status))
            }
        }
        .padding(.top, MobileDesign.Spacing.xSmall)
        .accessibilityIdentifier("memory.card.ledger")
    }

    private static func ledgerGlyph(_ status: MemoryIdeaCoverage.Status) -> String {
        switch status {
        case .produced: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .missing: "circle.dashed"
        }
    }

    private static func ledgerLabel(_ status: MemoryIdeaCoverage.Status) -> String {
        switch status {
        case .produced: "Came back"
        case .partial: "Partly"
        case .missing: "Not yet"
        }
    }

    /// The honest miss on a topic card: one tap sends it as the answer, so
    /// it is graded like one and the tutor moves on without a typed excuse.
    private var dontRememberButton: some View {
        Button {
            isComposerFocused = false
            Task { await viewModel.dontRemember() }
        } label: {
            Text(MemoryReviewTutoring.dontRememberMessage.trimmingCharacters(in: .punctuationCharacters))
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("memory.dontRemember")
    }

    private var workingLine: some View {
        HStack(spacing: 8) {
            ForeverLMLoadingIndicator(width: ForeverLMLoadingIndicator.inlineWidth, style: .flowingGoo)
            Text(viewModel.workingLabel.isEmpty ? "Thinking" : viewModel.workingLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("memory.working")
    }

    /// The same two words the Mac shows under a graded reply. A tap is the
    /// learner's steer, recorded on the exchange and sent as their message.
    private var steerChips: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            steerChip("Go deeper", systemImage: "arrow.down.right.circle", steer: .deeper)
            steerChip(viewModel.isTopicReview ? "Next topic" : "Next", systemImage: "arrow.right.circle", steer: .next)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory review steer")
    }

    private func steerChip(_ title: String, systemImage: String, steer: MemoryReviewSteer) -> some View {
        Button {
            isComposerFocused = false
            Task { await viewModel.steer(steer) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(steer == .next ? "memory.next" : "memory.deeper")
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
            TextField("Say it in your own words", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isComposerFocused)
                .submitLabel(.send)
                .onSubmit { Task { await viewModel.send() } }
                .disabled(viewModel.isResponding || !viewModel.canCompose)
                .accessibilityIdentifier("memory.composer")

            Button {
                isComposerFocused = false
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("memory.send")
        }
        .padding(MobileDesign.Spacing.medium)
        .mobileFloatingSurface(interactive: true)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
    }
}

/// One transcript row: the tutor on the left in plain type, the learner on the
/// right in a bubble, like the phone's reading chat. A topic's opening
/// question is set larger, in a serif face, so it reads as the thing to
/// answer rather than as chat.
struct MobileMemoryReviewMessageRow: View {
    let message: MobileMemoryReviewMessage
    var isOpening = false

    var body: some View {
        HStack {
            if message.role == .learner { Spacer(minLength: MobileDesign.Spacing.xxLarge) }
            Group {
                if let rendered = message.rendered {
                    Text(rendered)
                } else {
                    Text(message.content)
                }
            }
            .font(isOpening ? .system(.title3, design: .serif) : .body)
            .textSelection(.enabled)
            .padding(message.role == .learner ? MobileDesign.Spacing.medium : 0)
            .background(
                message.role == .learner ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            if message.role == .tutor { Spacer(minLength: MobileDesign.Spacing.xxLarge) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .learner ? .trailing : .leading)
        .accessibilityLabel(message.role == .learner ? "You" : "Tutor")
        .accessibilityValue(message.content)
    }
}
