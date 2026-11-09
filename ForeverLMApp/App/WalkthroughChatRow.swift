#if os(macOS)
import SwiftUI

/// The walk as the chat draws it: the deck of cards the learner is on
/// (`WalkthroughCardDeck`, `WalkthroughDeckView`), the strip under the chat's
/// title (`WalkthroughPlaybackStrip`), and a step's animation
/// (`WalkthroughAnimationCard`). Since 2026-09-22 a step's turn is never drawn
/// as a row while the walk plays — the card is its picture — and a walk left
/// behind leaves its turns in the transcript as the Markdown they are, so the
/// chip row that used to head each turn is gone (2026-09-23).

/// What a step's animation card shows: an inline document the step carries,
/// or a saved animation's page pinned to a step (`WalkthroughAnimationReference`).
enum WalkthroughAnimationContent: Equatable {
    case inline(html: String)
    case hosted(url: URL)
}

/// A step's animation on its own card, with Enlarge opening it as a sheet.
/// Alone on the card since 2026-09-24, so an inline document has the room a
/// figure had.
struct WalkthroughAnimationCard: View {
    let content: WalkthroughAnimationContent
    let enlarge: () -> Void
    @Environment(\.walkthroughStage) private var onStage

    init(content: WalkthroughAnimationContent, enlarge: @escaping () -> Void) {
        self.content = content
        self.enlarge = enlarge
    }

    init(html: String, enlarge: @escaping () -> Void) {
        self.init(content: .inline(html: html), enlarge: enlarge)
    }

    @ViewBuilder
    private var webView: some View {
        switch content {
        case .inline(let html):
            WalkthroughAnimationWebView(html: html)
                .frame(height: onStage ? 520 : 360)
        case .hosted(let url):
            // A kit page's stage is 1000 × 660; the card keeps that shape.
            WalkthroughHostedAnimationWebView(url: url)
                .aspectRatio(1000.0 / 660.0, contentMode: .fit)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            webView
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
            HStack {
                Spacer()
                Button(action: enlarge) {
                    Label("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.hoverWash)
                .help("Play the animation larger")
                .accessibilityIdentifier("walkthrough.animation.enlarge")
            }
        }
        // A group of its own: on a plain container the identifier replaced
        // Enlarge's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.animation")
    }
}

/// One point, alone on its card (product owner, 2026-09-23: "there should just be
/// like one point at a time"): the beat the walk is on, set large, and
/// nothing of the beats before or after it. The step's title above it and
/// the figure beside it say where the point belongs.
struct WalkthroughCardPoint: View {
    let text: String
    @Environment(\.walkthroughStage) private var onStage

    var body: some View {
        Text(Self.inline(text))
            .zoomedSystemFont(size: onStage ? 26 : 18, weight: onStage ? .regular : .medium)
            .lineSpacing(onStage ? 6 : 3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("walkthrough.card.point")
    }

    /// A beat's inline Markdown — bold, italics, code — as the text shows it.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Whether the card is drawn on the stage — the whole pane, with nothing said
/// under it yet — so its words are set for reading at a distance rather than
/// for a card above a chat (`WalkthroughCardDeck.fillsPane`).
private struct WalkthroughStageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var walkthroughStage: Bool {
        get { self[WalkthroughStageKey.self] }
        set { self[WalkthroughStageKey.self] = newValue }
    }
}

/// The walk as a deck of cards, one point a card (product owner, 2026-09-22:
/// "almost like cards that you go through … each card just has bite sized
/// chunks"; 2026-09-23: "one point at a time … interspersed with some
/// questions"). The card the learner is on holds one thing: a point of the
/// step, under the step's title, with the figure or panel it is about cut
/// out of the PDF above it — or a question, asked on a card of its own. The
/// authors' sentence is no longer on the face (2026-09-23: "I don't like
/// that they have these quotes on there"); on the Mac the page beside the
/// card has it. Under the card, the transcript holds that card's own
/// conversation and the composer asks about it. A card can be folded to its
/// title line to give the chat the room.
struct WalkthroughCardDeck<Figure: View, Face: View, Chip: View>: View {
    let steps: [PaperWalkthroughStep]
    /// The step the learner is on, and which of its cards.
    let currentIndex: Int
    let stepCardIndex: Int
    let stepCardCount: Int
    /// The card's place in the whole deck, one-based, and the deck's size.
    let cardOrdinal: Int
    let cardCount: Int
    let playedStepIDs: Set<String>
    /// The small line over the face: the step's title, a question's kind
    /// ("Predict"), or a chapter's title over its recap.
    let eyebrowText: String
    /// Whether the eyebrow draws in accent: a question or a recap does.
    let eyebrowAccent: Bool
    /// How tall the card may grow before it scrolls inside itself.
    let maxCardHeight: CGFloat
    /// The card takes the whole pane: nothing has been said under it, so
    /// there is no conversation to leave room for (product owner, 2026-09-24: "it
    /// can basically take up the whole screen and just walk through the
    /// paper"). The figure grows to the pane, the point is set large under
    /// it, and the deck's controls sit at the foot. A question typed under
    /// the card hands the room back and the card returns to its compact form.
    var fillsPane: Bool = false
    /// What the walk is getting ready — the next step, say — while the card
    /// on show waits for it. The stage keeps the card up through the wait
    /// and says it at its foot; the compact card leaves it to the
    /// transcript's working line.
    var preparationDetail: String? = nil
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    @Binding var isFolded: Bool
    let canGoBack: Bool
    let canGoNext: Bool
    let back: () -> Void
    let next: () -> Void
    let jump: (Int) -> Void
    /// The figure or panel the card is about, no taller than it is handed.
    @ViewBuilder let figure: (CGFloat) -> Figure
    @ViewBuilder let face: () -> Face
    /// What the card points at, as a small control in the footer.
    @ViewBuilder let chip: () -> Chip

    /// The card's own height, measured inside its scroll view.
    @State private var contentHeight: CGFloat = 0

    private var currentStep: PaperWalkthroughStep? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    /// Which card is up: the step and its card within it.
    private var cardKey: String {
        "\(currentStep?.id ?? "")#\(stepCardIndex)"
    }

    /// The figure's height on the compact card.
    static var compactFigureHeight: CGFloat { 280 }

    var body: some View {
        if fillsPane {
            stage
        } else {
            compactCard
        }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFolded {
                foldedLine
            } else {
                // One copy of the card, in a scroll view as tall as the card
                // measures, up to the cap. Its height is its own, not the
                // share the chat under it leaves: a `ViewThatFits` here built
                // two copies (each loading its own figure) and could draw the
                // plain one in a frame sized for the other, so the figure
                // shrank to a thumbnail and the text ran out under the footer
                // until the next layout (2026-09-24).
                ScrollView(.vertical) {
                    cardContent
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            contentHeight = height
                        }
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, maxCardHeight))
            }
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .padding(.horizontal, gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: columnMaxWidth)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: cardKey)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.card")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            eyebrow
            // Next swaps what changed, not the card: the figure keeps its
            // identity across a step's cards so it neither reloads nor
            // blinks, and only the point under it crossfades. (2026-09-23:
            // the whole card used to fly in from the right on every Next.)
            figure(Self.compactFigureHeight)
                .id(currentStep?.id ?? "")
                .transition(.opacity)
            // The crossfade sits in a ZStack, so the outgoing face and the
            // incoming one overlap while they fade instead of stacking.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    face()
                }
                .id(cardKey)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card as the whole pane: the walk's progress across the top, the
    /// card centred in the room left — its figure as tall as a little over
    /// half of it, the point under it — and Back and Next at the foot. No
    /// frame around it: the pane is the card.
    private var stage: some View {
        VStack(spacing: 0) {
            stepSegments(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 6)
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    stageContent(figureHeight: max(Self.compactFigureHeight, proxy.size.height * 0.58))
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
            }
            stageFooter
        }
        .environment(\.walkthroughStage, true)
        .padding(.horizontal, gutter)
        .frame(maxWidth: columnMaxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: cardKey)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.card")
    }

    private func stageContent(figureHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            eyebrow
            figure(figureHeight)
                .id(currentStep?.id ?? "")
                .transition(.opacity)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 18) {
                    face()
                }
                .id(cardKey)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    /// What the card points at, then Back and a Next that reads as the way
    /// on. No fold: there is no conversation to fold the card for.
    private var stageFooter: some View {
        HStack(spacing: 12) {
            chip()
            Spacer(minLength: 12)
            // Held back a moment so a quick deal shows nothing, and in a slot
            // of its own so it never moves Back and Next.
            ZStack {
                if let preparationDetail {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.4)),
                            removal: .identity
                        ))
                        .help(preparationDetail)
                        .accessibilityLabel(preparationDetail)
                        .accessibilityIdentifier("walkthrough.card.preparing")
                }
            }
            .frame(width: 20, height: 20)
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 14, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.1))
            .disabled(!canGoBack)
            .help("Back")
            .accessibilityIdentifier("walkthrough.card.back")
            Button(action: next) {
                HStack(spacing: 6) {
                    Text("Next")
                    Image(systemName: "arrow.right")
                }
                .zoomedSystemFont(size: 14, weight: .semibold)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canGoNext)
            .help(canGoNext ? "Next" : "The end of the walk")
            .accessibilityIdentifier("walkthrough.card.next")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    /// The step's title, small, over its cards — the one line that says what
    /// the point belongs to — and the card's place in the deck.
    private var eyebrow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(eyebrowText)
                .zoomedSystemFont(size: fillsPane ? 12 : 11, weight: .semibold)
                .foregroundStyle(eyebrowAccent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .textCase(.uppercase)
                .kerning(fillsPane ? 0.8 : 0.4)
                .lineLimit(1)
                .accessibilityIdentifier("walkthrough.card.title")
            Spacer(minLength: 0)
            Text("\(cardOrdinal) / \(cardCount)")
                .zoomedSystemFont(size: fillsPane ? 12 : 11, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .textSelection(.disabled)
                .accessibilityLabel("Card \(cardOrdinal) of \(cardCount)")
                .accessibilityIdentifier("walkthrough.card.ordinal")
        }
    }

    private var foldedLine: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isFolded = false }
        } label: {
            HStack(spacing: 8) {
                Text("\(cardOrdinal)")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                Text(currentStep?.title ?? "")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0, opacity: 0.05))
        .help("Show the card")
        .accessibilityIdentifier("walkthrough.card.unfold")
    }

    /// One segment a step, the current one filling card by card, each a jump;
    /// what the card points at; Back and Next; and the fold.
    private var footer: some View {
        HStack(spacing: 8) {
            stepSegments(maxWidth: 320)
            Spacer(minLength: 8)
            chip()
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(!canGoBack)
            .help("Back")
            .accessibilityIdentifier("walkthrough.card.back")
            Button(action: next) {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(!canGoNext)
            .help(canGoNext ? "Next" : "The end of the walk")
            .accessibilityIdentifier("walkthrough.card.next")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isFolded.toggle() }
            } label: {
                Image(systemName: isFolded ? "chevron.down" : "chevron.up")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help(isFolded ? "Show the card" : "Fold the card to its title, to give its questions room")
            .accessibilityIdentifier("walkthrough.card.fold")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Divider().opacity(isFolded ? 0 : 1) }
    }

    /// The walk as a row of segments, one a step: the steps before this one
    /// full, this one filled as far as its cards have been dealt, the rest
    /// faint. Pressing a segment jumps to that step.
    private func stepSegments(maxWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    jump(index)
                } label: {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(segmentTint(index: index, step: step))
                                .frame(width: proxy.size.width * segmentFill(index: index))
                        }
                    }
                    .frame(height: 3)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(index + 1). \(step.title)")
                .accessibilityLabel("Step \(index + 1): \(step.title)")
            }
        }
        .frame(maxWidth: maxWidth)
        // A group of its own: on a plain container every step's button
        // carried the identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.card.steps")
    }

    private func segmentFill(index: Int) -> CGFloat {
        if index < currentIndex { return 1 }
        if index == currentIndex { return CGFloat(stepCardIndex) / CGFloat(max(1, stepCardCount)) }
        return 0
    }

    private func segmentTint(index: Int, step: PaperWalkthroughStep) -> Color {
        if index == currentIndex { return .accentColor }
        if index < currentIndex || playedStepIDs.contains(step.id) { return Color.accentColor.opacity(0.45) }
        return .clear
    }
}

/// What the card points at, as one small control in its footer: the figure
/// and panel ("Figure 2b"), a video's moment ("12:34"), the quoted passage,
/// or the saved animation and its step. Pressing it points the Reader — or
/// the Animations pane — there again without moving the walk (product owner,
/// 2026-09-19: "i should be able to click somewhere here and go straight to
/// the figure").
struct WalkthroughCardAnchorChip: View {
    let step: PaperWalkthroughStep
    let resolved: WalkthroughResolvedAnchor?
    var animationTitle: String? = nil
    let refocus: () -> Void

    private var label: (symbol: String, text: String, help: String)? {
        if let anchor = step.anchor, let figure = anchor.figureLabel, !figure.isEmpty {
            let panel = resolved?.panel ?? anchor.panelLabel.map(PaperWalkthroughValidation.panelDisplayName)
            let text = PaperWalkthroughValidation.figurePanelLabel(figure, panel: panel)
            return ("scope", text, "Show \(text) in the source")
        }
        if let reference = step.animation {
            return ("play.rectangle", "\(animationTitle ?? "Animation") · \(reference.summary)", "Show this step of the animation")
        }
        if let clock = step.anchor?.momentClock {
            return ("clock", clock, "Show the video at \(clock)")
        }
        if let passage = step.anchor?.passage, !passage.isEmpty {
            return ("text.quote", "In the text", "Show this passage in the source")
        }
        return nil
    }

    var body: some View {
        if let label {
            Button(action: refocus) {
                HStack(spacing: 4) {
                    Image(systemName: label.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(label.text)
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.1))
            .help(label.help)
            .accessibilityIdentifier("walkthrough.showAnchor")
        }
    }
}

/// A question card, in the manner of quantum.country's mnemonic medium
/// (product owner, 2026-09-22: "ask smart questions along the way … reading and
/// quizzing within one interface"; 2026-09-23: "one point at a time
/// interspersed with some questions"): the question is the whole card. The
/// learner answers in their head — or types into the chat below to have it
/// graded — then shows the answer and says whether they had it.
struct WalkthroughRecallPrompt: View {
    let quiz: PaperWalkthroughQuiz
    /// The reminder the writer gave the question of what it is about, drawn
    /// small above it; nil for a question that stands alone.
    var context: String? = nil
    let recall: ReviewSessionManager.WalkthroughRecall?
    let canGoNext: Bool
    /// A Find it's panels (letters, or names such as "DESIGN"), each a chip
    /// that answers; empty for the other kinds or a figure whose panels are
    /// not known.
    var findPanels: [String] = []
    /// A Find it picked wrong once: one more try before the answer shows.
    var missedOnce: Bool = false
    let reveal: () -> Void
    let grade: (Bool) -> Void
    var pick: ((String) -> Void)? = nil
    let next: () -> Void
    @Environment(\.walkthroughStage) private var onStage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let context, !context.isEmpty {
                Text(WalkthroughCardPoint.inline(context))
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("walkthrough.recall.context")
            }
            Text(WalkthroughCardPoint.inline(quiz.question))
                .zoomedSystemFont(size: onStage ? 24 : 18, weight: .semibold)
                .lineSpacing(onStage ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("walkthrough.recall.question")
            if recall == nil {
                if quiz.kind == .find, !findPanels.isEmpty, let pick {
                    // Answered on the figure: a chip a panel here, or a click
                    // on the panel in the Reader.
                    HStack(spacing: 6) {
                        ForEach(findPanels, id: \.self) { letter in
                            Button {
                                pick(letter)
                            } label: {
                                Text(PaperWalkthroughValidation.panelDisplayName(letter))
                                    .zoomedSystemFont(size: 13, weight: .semibold)
                                    .monospaced()
                                    .frame(minWidth: 30, minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                            )
                            .foregroundStyle(Color.accentColor)
                            .help("Panel \(PaperWalkthroughValidation.panelDisplayName(letter))")
                            .accessibilityIdentifier("walkthrough.find.\(letter.lowercased())")
                        }
                        Spacer(minLength: 0)
                        Button(action: reveal) {
                            Text("Show answer")
                                .zoomedSystemFont(size: 12)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverWash)
                        .accessibilityIdentifier("walkthrough.recall.reveal")
                    }
                    if missedOnce {
                        Text("Not that one — look again at what each panel plots.")
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("walkthrough.find.miss")
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(quiz.kind == .predict ? "Guess below, or" : "Answer below, or")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.tertiary)
                        Button(action: reveal) {
                            Text("Show answer")
                                .zoomedSystemFont(size: 12, weight: .semibold)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.1))
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("walkthrough.recall.reveal")
                        Spacer(minLength: 0)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text(WalkthroughCardPoint.inline(quiz.answer))
                        .zoomedSystemFont(size: onStage ? 18 : 15)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !quiz.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(quiz.keyPoints.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(WalkthroughCardPoint.inline(point))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .zoomedSystemFont(size: 12)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("walkthrough.recall.answer")
                switch recall {
                case .revealed:
                    HStack(spacing: 8) {
                        gradeButton("Forgot", systemImage: "arrow.counterclockwise", tint: .secondary, remembered: false)
                        gradeButton("Remembered", systemImage: "checkmark", tint: .accentColor, remembered: true)
                    }
                case .remembered, .forgot, .answered:
                    HStack(spacing: 8) {
                        Label(
                            recall == .remembered ? "Remembered" : (recall == .answered ? "Graded below" : "Marked to come back to"),
                            systemImage: recall == .remembered ? "checkmark.circle.fill" : (recall == .answered ? "text.bubble" : "arrow.counterclockwise.circle")
                        )
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .foregroundStyle(recall == .remembered ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                        Spacer(minLength: 0)
                        if canGoNext {
                            Button(action: next) {
                                HStack(spacing: 3) {
                                    Text("Next card")
                                    Image(systemName: "chevron.right")
                                }
                                .zoomedSystemFont(size: 12, weight: .semibold)
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash)
                            .accessibilityIdentifier("walkthrough.recall.next")
                        }
                    }
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: recall)
        // A group of its own: on a plain container the identifier replaced
        // the question's, Show answer's, the panel chips', the grades' and
        // Next card's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.recall")
    }

    private func gradeButton(_ title: String, systemImage: String, tint: Color, remembered: Bool) -> some View {
        Button {
            grade(remembered)
        } label: {
            Label(title, systemImage: systemImage)
                .zoomedSystemFont(size: 12, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.1))
        .foregroundStyle(tint)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .help(remembered ? "I had it" : "I didn't have it; come back to this")
        .accessibilityIdentifier(remembered ? "walkthrough.recall.remembered" : "walkthrough.recall.forgot")
    }
}

/// Say more chips under a card's point (the lesson's, merged 2026-09-23):
/// context offered, never pushed. Pressing a chip opens its words under the
/// point, labelled general knowledge when they are not the source's own.
struct WalkthroughMoreChips: View {
    let more: [PaperWalkthroughMore]
    @State private var opened: Set<String> = []

    var body: some View {
        if !more.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(more, id: \.label) { chip in
                        let isOpen = opened.contains(chip.label)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if isOpen { opened.remove(chip.label) } else { opened.insert(chip.label) }
                            }
                        } label: {
                            Text(chip.label)
                                .zoomedSystemFont(size: 11, weight: .medium)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0, opacity: 0.1))
                        .background(Color.accentColor.opacity(isOpen ? 0.14 : 0.07), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .help(chip.fromPaper ? "In the source's own words" : "General knowledge, not from the source")
                        .accessibilityIdentifier("walkthrough.more.chip")
                    }
                    Spacer(minLength: 0)
                }
                ForEach(more.filter { opened.contains($0.label) }, id: \.label) { chip in
                    VStack(alignment: .leading, spacing: 3) {
                        if !chip.fromPaper {
                            Text("General knowledge")
                                .zoomedSystemFont(size: 10, weight: .semibold)
                                .textCase(.uppercase)
                                .foregroundStyle(.tertiary)
                                .textSelection(.disabled)
                        }
                        Text(WalkthroughCardPoint.inline(chip.text))
                            .zoomedSystemFont(size: 13)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 2)
                    .accessibilityIdentifier("walkthrough.more.text")
                }
            }
            // A group of its own: on a plain container the identifier replaced
            // each chip's walkthrough.more.chip.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("walkthrough.more")
        }
    }
}

/// The works a step cites, under the card's point (product owner, 2026-09-30: "if
/// a walkthrough ever cites a paper or article, it would be nice if that
/// source was actually shown there in a nice way"): one source card each.
struct WalkthroughCitedWorks: View {
    let citations: [PaperWalkthroughCitation]
    /// The walked source, whose recorded cited papers can lend a work named
    /// without an address the one the catalogs resolved.
    let citedBySourceID: String

    var body: some View {
        if !citations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(citations, id: \.identityKey) { citation in
                    WalkthroughCitedWorkCard(citation: citation, citedBySourceID: citedBySourceID)
                }
            }
            // A group of its own: on a plain container the identifier
            // replaced each card's.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("walkthrough.cites")
        }
    }
}

/// One cited work as a source card: the library's own thumbnail when it
/// holds the work (a paper's first page, a book's cover), else the kind's
/// glyph; what it is, its title and its byline. A click opens it where a
/// chat's citation opens: the saved copy in the Reader, else its page in the
/// Reader, with Add beside it to keep it; a work named with no address looks
/// itself up on Google Scholar in the browser.
private struct WalkthroughCitedWorkCard: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.walkthroughStage) private var onStage
    let citation: PaperWalkthroughCitation
    let citedBySourceID: String

    @State private var match: WalkthroughCitationMatch?
    @State private var isAdding = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        let shown = match?.citation ?? citation
        let libraryID = match?.librarySourceID ?? vm.librarySourceID(for: shown)
        let article = libraryID.flatMap { vm.articlesById[$0] }
        HStack(alignment: .center, spacing: 10) {
            Button {
                open(shown, libraryID: article?.id)
            } label: {
                face(shown, article: article)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 9, inset: -5, opacity: 0.07))
            .help(helpText(shown, isHeld: article != nil))
            .accessibilityIdentifier("walkthrough.cites.open")
            trailing(shown, isHeld: article != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(shape.fill(Color.primary.opacity(0.035)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .frame(maxWidth: onStage ? 640 : .infinity, alignment: .leading)
        .contextMenu { menu(shown, libraryID: article?.id) }
        .task(id: citation) {
            match = await vm.walkthroughCitationMatch(citation, citedBy: citedBySourceID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.cites.card")
    }

    private func face(_ shown: PaperWalkthroughCitation, article: StudioArticle?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail(shown, article: article)
            VStack(alignment: .leading, spacing: 2) {
                Text(PaperWalkthroughCitation.eyebrow(kind: kind(of: shown, article: article)))
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .foregroundStyle(.tertiary)
                    .textSelection(.disabled)
                Text(shown.title)
                    .zoomedSystemFont(size: onStage ? 15 : 13, weight: .semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                if let byline = shown.byline {
                    Text(byline)
                        .zoomedSystemFont(size: onStage ? 12 : 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.disabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func thumbnail(_ shown: PaperWalkthroughCitation, article: StudioArticle?) -> some View {
        let size: CGFloat = onStage ? 46 : 38
        if let article {
            SourceThumbnail(source: article, size: size)
        } else {
            let citedKind = kind(of: shown, article: nil)
            let tint = Self.tint(for: citedKind)
            Image(systemName: citedKind?.symbolName ?? "text.quote")
                .zoomedSystemFont(size: size * 0.42)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    /// Add, while the library does not hold a work it can fetch; a quiet
    /// "In library" once it does.
    @ViewBuilder
    private func trailing(_ shown: PaperWalkthroughCitation, isHeld: Bool) -> some View {
        if isHeld {
            Text("In library")
                .zoomedSystemFont(size: 10)
                .foregroundStyle(.tertiary)
                .textSelection(.disabled)
        } else if let address = shown.address {
            Button {
                isAdding = true
                Task {
                    await vm.addCitedPageToSources(address)
                    isAdding = false
                }
            } label: {
                Label(isAdding ? "Adding" : "Add", systemImage: "plus")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -4, opacity: 0.10))
            .disabled(isAdding)
            .help("Add it to your library")
            .accessibilityIdentifier("walkthrough.cites.add")
        }
    }

    @ViewBuilder
    private func menu(_ shown: PaperWalkthroughCitation, libraryID: String?) -> some View {
        if let libraryID {
            Button("Open") { open(shown, libraryID: libraryID) }
            OtherWindowSourceMenuItem(sourceID: libraryID)
        } else if let address = shown.address {
            Button("Open Page") { open(shown, libraryID: nil) }
            Button("Add to Library") { Task { await vm.addCitedPageToSources(address) } }
        } else if let search = shown.scholarSearchURL {
            Button("Search Google Scholar") { WebLinkOpening.open(search) }
        }
        Divider()
        Button("Copy Citation") { Self.copy(shown.referenceLine) }
        if let address = shown.address {
            Button("Copy Link") { Self.copy(address.absoluteString) }
        }
    }

    private func open(_ shown: PaperWalkthroughCitation, libraryID: String?) {
        if let libraryID {
            Task { await vm.openLinkedSourceInReader(libraryID) }
        } else if let address = shown.address {
            vm.openWebCitationInReader(address, title: shown.title)
        } else if let search = shown.scholarSearchURL {
            WebLinkOpening.open(search)
        }
    }

    private func helpText(_ shown: PaperWalkthroughCitation, isHeld: Bool) -> String {
        if isHeld { return "Open it in the Reader" }
        if shown.address != nil { return "Open its page in the Reader" }
        return "Search for it on Google Scholar"
    }

    /// What the work is: as the walk said, else as the library holds it,
    /// else a paper when it has a DOI.
    private func kind(of shown: PaperWalkthroughCitation, article: StudioArticle?) -> PaperWalkthroughCitation.Kind? {
        if let kind = shown.kind { return kind }
        switch article?.sourceType {
        case .paper?: return .paper
        case .book?: return .book
        case .article?: return .article
        case .video?: return .video
        case .podcast?: return .podcast
        default: return shown.doi != nil ? .paper : nil
        }
    }

    /// The kind's colour, as a source row draws it (`SourceThumbnail`).
    static func tint(for kind: PaperWalkthroughCitation.Kind?) -> Color {
        switch kind {
        case .paper?: return .purple
        case .book?: return .green
        case .article?: return .blue
        case .video?: return .red
        case .podcast?: return .orange
        case nil: return .secondary
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A chapter's recap card (the lesson's, merged 2026-09-23): the claim the
/// learner can now say, and how the chapter's questions went.
struct WalkthroughRecapFace: View {
    let claim: String
    let remembered: Int
    let asked: Int
    @Environment(\.walkthroughStage) private var onStage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You can now say")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .textSelection(.disabled)
            Text(WalkthroughCardPoint.inline(claim))
                .zoomedSystemFont(size: onStage ? 26 : 18, weight: onStage ? .regular : .medium)
                .lineSpacing(onStage ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("walkthrough.recap.claim")
            if asked > 0 {
                Text("\(remembered) of \(asked) \(asked == 1 ? "question" : "questions") remembered")
                    .zoomedSystemFont(size: 12)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .accessibilityIdentifier("walkthrough.recap.score")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A group of its own: on a plain container the identifier replaced
        // the claim's and the score's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.recap")
    }
}

/// The figure a card is about, cut out of the paper: the panel alone when the
/// card is on one panel (the resolver's lens), otherwise the whole figure's
/// rectangle on its page. Pressing it opens it large; nothing shows for a
/// card on a passage or a page, whose picture is the page in the Reader.
struct WalkthroughCardFigure: View {
    let sourceID: String
    let resolved: WalkthroughResolvedAnchor?
    let caption: String?
    let articleForSourceID: @MainActor (String) async -> StudioArticle?
    /// A prediction's data covered until the learner has guessed (the
    /// lesson's veil, merged 2026-09-23): the crop is blurred under a line
    /// that says why.
    var veiled: Bool = false
    /// The tallest the crop may draw: the compact card's 280, or most of the
    /// pane on the stage.
    var maxHeight: CGFloat = 280
    @Environment(\.walkthroughStage) private var onStage

    @State private var image: ChatSourceImage?

    private var key: String {
        guard let resolved else { return "none" }
        if let lens = resolved.lensImage { return "lens:\(resolved.panel ?? ""):\(lens.count)" }
        if let reference = figureReference { return reference.urlString }
        return "none"
    }

    private var figureReference: SourceImageReference? {
        guard case .figure(let pageIndex, let rect, _, _)? = resolved?.target,
              let rect, rect.isValid else { return nil }
        return SourceImageReference(sourceID: sourceID, location: .page(pageIndex + 1), crop: rect)
    }

    var body: some View {
        // A zero-height stand-in keeps the view (and its task) alive while
        // there is no picture yet; an empty Group would never appear.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let image, let nsImage = NSImage(data: image.data) {
                Button {
                    ChatImageLightbox.present(image, title: caption, over: nil)
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .blur(radius: veiled ? 14 : 0)
                        .overlay {
                            if veiled {
                                Text("Hidden until you answer")
                                    .zoomedSystemFont(size: 12, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.thinMaterial, in: Capsule())
                                    .textSelection(.disabled)
                                    .accessibilityIdentifier("walkthrough.card.veil")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: maxHeight)
                        .padding(onStage ? 20 : 8)
                        .background(
                            RoundedRectangle(cornerRadius: onStage ? 16 : 10, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(onStage ? 0.10 : 0), radius: 18, y: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: onStage ? 16 : 10, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(veiled)
                .help(veiled ? "Answer first" : "Open the figure large")
                .accessibilityIdentifier("walkthrough.card.figure")
            }
        }
        .task(id: key) {
            guard let resolved else { image = nil; return }
            if let lens = resolved.lensImage {
                image = ChatSourceImage(data: lens, mediaType: "image/jpeg")
            } else if let reference = figureReference {
                image = await ChatSourceImage.resolved(token: reference.urlString, articleForSourceID: articleForSourceID)
            } else {
                image = nil
            }
        }
    }
}

/// A picture drawn for a card (`PaperWalkthroughPicture.imageID`), read from
/// this Mac's store of drawn pictures and set on the same white plate as a
/// figure. Pressing it opens it large; right-clicking it says which model drew
/// it and draws it again with another (`GeneratedImageRedraw`). A picture
/// another Mac drew arrives with the Source record (`WalkthroughPicturePackage`);
/// until it has, the card shows none rather than a placeholder, and reads the
/// store again when it lands.
struct WalkthroughCardDrawnPicture: View {
    let imageID: String
    /// The brief it was drawn from, as the enlarged picture's title.
    let caption: String?
    var maxHeight: CGFloat = 280
    @Environment(\.walkthroughStage) private var onStage
    @Environment(StudioViewModel.self) private var vm: StudioViewModel?

    @State private var image: ChatSourceImage?
    /// The version shown and what made it.
    @State private var listing: GeneratedImageStore.Listing?
    /// Bumped when a redraw of this picture lands, to read it again.
    @State private var redraws = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let image, let nsImage = NSImage(data: image.data) {
                let redrawing = listing.map { GeneratedImageRedrawCenter.shared.inFlight[$0.id] != nil } ?? false
                Button {
                    ChatImageLightbox.present(image, title: caption, over: nil)
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: maxHeight)
                        .padding(onStage ? 20 : 8)
                        .background(
                            RoundedRectangle(cornerRadius: onStage ? 16 : 10, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(onStage ? 0.10 : 0), radius: 18, y: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: onStage ? 16 : 10, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                        .opacity(redrawing ? 0.4 : 1)
                        .overlay {
                            if redrawing { ProgressView().controlSize(.small) }
                        }
                        .animation(.easeInOut(duration: 0.2), value: redrawing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the picture large")
                .contextMenu {
                    if let listing {
                        GeneratedImageRedrawMenuItems(listing: listing) { model in
                            Task {
                                await GeneratedImageRedrawCenter.shared.redraw(
                                    id: listing.id, with: model, usageTask: "walkthrough_picture", vm: vm
                                )
                            }
                        }
                    }
                }
                .accessibilityLabel(caption ?? "Picture")
                .accessibilityIdentifier("walkthrough.card.picture")
            }
        }
        .task(id: "\(imageID)#\(redraws)") {
            let id = imageID
            let stored = await Task.detached(priority: .userInitiated) {
                // The image's latest version when the id names the image, so
                // a picture revised from its notebook or a chat shows revised,
                // and a version redrawn shows its redraw.
                GeneratedImageStore.readImageOrVersion(id)
            }.value
            image = stored.map { ChatSourceImage(data: $0.image.data, mediaType: $0.image.mediaType) }
            listing = stored?.listing
        }
        .onReceive(NotificationCenter.default.publisher(for: .generatedImageRedrawn)) { note in
            let image = note.userInfo?[GeneratedImageRedraw.imageIDKey] as? String
            let replaced = (note.userInfo?[GeneratedImageRedraw.replacedKey] as? [String]) ?? []
            guard image == listing?.imageID || replaced.contains(imageID.lowercased()) else { return }
            redraws += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .generatedImagesArrived)) { note in
            // The picture came in with the Source record from the Mac that
            // drew it (`WalkthroughPicturePackage`), after the card was dealt.
            let arrived = (note.userInfo?[GeneratedImageStore.changedIDsKey] as? [String]) ?? []
            guard arrived.contains(imageID.lowercased()) || listing.map({ arrived.contains($0.imageID) }) == true else { return }
            redraws += 1
        }
    }
}

/// Where the learner is in the walk, as a thin strip under the chat's title
/// while a record is attached: the walk's title, "step n of m", Back (which
/// points the Reader at the previous step without another turn), Next (which
/// plays the next step) and a menu to jump to any step. A header widget, not
/// a panel.
struct WalkthroughPlaybackStrip: View {
    let title: String
    let steps: [PaperWalkthroughStep]
    let currentIndex: Int
    /// The card the learner is on, one-based across the whole deck, and the
    /// deck's size (`PaperWalkthrough.cardOrdinal`, `cardCount`).
    var cardOrdinal: Int = 0
    var cardCount: Int = 0
    let playedStepIDs: Set<String>
    /// Whether Back and Next have somewhere to go — a beat of the step, or
    /// another step (`WalkthroughPlayback.canGoBack`, `canGoNext`).
    let canGoBack: Bool
    let canGoNext: Bool
    /// True while a turn is in flight; Next then would land mid-reply.
    let isBusy: Bool
    /// Back and Next up here; off while the card has the pane, whose own
    /// Next is the way on.
    var showsStepControls: Bool = true
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    let back: () -> Void
    let next: () -> Void
    let jump: (Int) -> Void
    /// Leaves the walk: the strip goes, the page's outline comes down, and
    /// the pane opens New chat. The walk keeps its place.
    let leave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .foregroundStyle(Color.accentColor)
                .zoomedSystemFont(size: 11, weight: .semibold)
            Menu {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        jump(index)
                    } label: {
                        Label {
                            Text("\(index + 1). \(step.title)")
                        } icon: {
                            Image(systemName: index == currentIndex
                                  ? "circle.inset.filled"
                                  : (playedStepIDs.contains(step.id) ? "checkmark.circle" : step.kind.symbolName))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .lineLimit(1)
                    Text(cardCount > 0
                         ? "· card \(cardOrdinal) of \(cardCount)"
                         : "· step \(min(currentIndex, max(0, steps.count - 1)) + 1) of \(steps.count)")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Jump to a step")
            .accessibilityIdentifier("walkthrough.strip.steps")
            Spacer(minLength: 0)
            if showsStepControls {
                stepControls
            }
            // The way out. A walk is a mode the chat is in, and a mode with no
            // visible exit is a trap (product owner, 2026-09-21: "I'm not seeing any
            // press X to close in the top right here for this walkthrough.
            // That's pretty bad."). It ends the walk and opens New chat's
            // greeting (product owner, 2026-09-29: "should just close it and open
            // that good afternoon the product owner chat page"); the walk's place is
            // kept, and the outline comes off the page.
            Button(action: leave) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .help("Leave the walk. It keeps your place.")
            .accessibilityLabel("Leave the walk")
            .accessibilityIdentifier("walkthrough.leave")
        }
        .padding(.horizontal, gutter)
        .padding(.vertical, 5)
        .frame(maxWidth: columnMaxWidth)
        .frame(maxWidth: .infinity)
        // A group of its own: on a plain container the identifier replaced
        // the steps menu's, Back's, Next's and Leave's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.strip")
    }

    private var stepControls: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(!canGoBack)
            .help("Back")
            .accessibilityIdentifier("walkthrough.back")
            Button(action: next) {
                HStack(spacing: 3) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
                .zoomedSystemFont(size: 11, weight: .semibold)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash)
            .disabled(!canGoNext || isBusy)
            .help(canGoNext ? "Next" : "The end of the walk")
            .accessibilityIdentifier("walkthrough.next")
        }
    }
}

/// Where a walk's step turns sit in a chat that is not playing it: one row
/// for the walk, at the card asked about last, that deals the cards again
/// from where the walk's own record left them (`WalkthroughTranscriptFold.resting`,
/// `WalkthroughProgress`). The turns themselves are the cards' words and are
/// never drawn as replies.
struct WalkthroughResumeRow: View {
    let title: String
    let maxContentWidth: CGFloat
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(Color.accentColor)
                .zoomedSystemFont(size: 13, weight: .semibold)
            VStack(alignment: .leading, spacing: 1) {
                Text("Walkthrough of \(title)")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                Text("Resume picks the cards up where you left them")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Resume", action: resume)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Go back to the cards, on the step you stopped at")
                .accessibilityIdentifier("walkthrough.resume")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.resumeRow")
    }
}
/// A step's animation opened large, from a card.
struct WalkthroughEnlargedAnimation: Identifiable {
    let id: String
    let title: String
    let content: WalkthroughAnimationContent
}

/// The card the walk is on, built from the chat's playback and drawn above
/// the chat's transcript. One point a card: the step's beat the
/// playback has revealed last is the card's face, its ordinal counted in
/// cards across the walk; the question, when the step asks one, is the
/// step's last card.
struct WalkthroughDeckView: View {
    let manager: ReviewSessionManager
    /// True while a turn is in flight; Next then would land mid-reply.
    let isBusy: Bool
    let maxCardHeight: CGFloat
    /// The card takes the whole pane (`WalkthroughCardDeck.fillsPane`).
    var fillsPane: Bool = false
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    @Binding var isFolded: Bool
    let articleForSourceID: @MainActor (String) async -> StudioArticle?
    let enlargeAnimation: (WalkthroughEnlargedAnimation) -> Void

    var body: some View {
        if let playback = manager.walkthroughPlayback,
           let step = playback.currentStep,
           playback.playedStepIDs.contains(step.id) {
            let beats = playback.walkthrough.playableBeats(of: step)
            let revealed = playback.revealedBeatCount(of: step)
            let beat = beats.indices.contains(revealed - 1) ? beats[revealed - 1] : nil
            let resolved = manager.walkthroughResolvedByStep[step.id]
            let record = playback.figureRecord(for: step)
            let stepCards = playback.walkthrough.cardCount(of: step)
            let recall = playback.recall[step.id]
            let quiz = step.quiz
            let onQuestion = beat?.kind == .question
            let veiled = onQuestion && quiz?.kind == .predict && recall == nil
            WalkthroughCardDeck(
                steps: playback.steps,
                currentIndex: playback.currentIndex,
                stepCardIndex: revealed,
                stepCardCount: stepCards,
                cardOrdinal: playback.walkthrough.cardOrdinal(stepIndex: playback.currentIndex, card: revealed),
                cardCount: playback.walkthrough.cardCount,
                playedStepIDs: playback.playedStepIDs,
                eyebrowText: Self.eyebrow(for: beat, step: step),
                eyebrowAccent: beat?.kind == .question || beat?.kind == .recap,
                maxCardHeight: maxCardHeight,
                fillsPane: fillsPane,
                preparationDetail: manager.walkthroughPreparationDetail,
                columnMaxWidth: columnMaxWidth,
                gutter: gutter,
                isFolded: $isFolded,
                canGoBack: playback.canGoBack,
                canGoNext: playback.canGoNext && !isBusy,
                back: { Task { await manager.walkthroughBack() } },
                next: { Task { await manager.walkthroughNext() } },
                jump: { index in Task { await manager.showWalkthroughStep(at: index) } },
                figure: { figureHeight in
                    // A point card always has a picture when the walk has
                    // one to give (product owner, 2026-09-24): the figure the step
                    // outlines, else the step's own picture or the one an
                    // earlier step of its chapter showed. A question card
                    // shows only its own step's figure — veiled on a
                    // prediction until the guess is in — so a borrowed
                    // picture never gives an answer away. The recap card
                    // carries none, and the animation card is the animation
                    // alone.
                    switch beat?.kind {
                    case .point, nil:
                        cardPicture(step: step, playback: playback, resolved: resolved, record: record, maxHeight: figureHeight)
                    case .question:
                        if step.anchor?.figureLabel != nil {
                            WalkthroughCardFigure(
                                sourceID: playback.sourceID,
                                resolved: resolved,
                                caption: record.flatMap { PaperFigureCaptionTitle.title(from: $0.caption) } ?? step.anchor?.figureDisplayLabel,
                                articleForSourceID: articleForSourceID,
                                veiled: veiled,
                                maxHeight: figureHeight
                            )
                        }
                    case .recap, .animation:
                        EmptyView()
                    }
                },
                face: {
                    if let beat {
                        switch beat.kind {
                        case .point:
                            WalkthroughCardPoint(text: beat.text)
                            WalkthroughMoreChips(more: step.more)
                            WalkthroughCitedWorks(citations: step.cites, citedBySourceID: playback.sourceID)
                        case .question:
                            if let quiz {
                                WalkthroughRecallPrompt(
                                    quiz: quiz,
                                    context: beat.context,
                                    recall: recall,
                                    canGoNext: playback.canGoNext && !isBusy,
                                    findPanels: quiz.kind == .find ? (resolved?.panelLabels ?? []) : [],
                                    missedOnce: (manager.walkthroughFindMisses[step.id] ?? 0) > 0,
                                    reveal: { manager.revealWalkthroughAnswer() },
                                    grade: { remembered in Task { await manager.gradeWalkthroughRecall(remembered: remembered) } },
                                    pick: { letter in Task { await manager.pickWalkthroughPanel(sourceID: playback.sourceID, panel: letter) } },
                                    next: { Task { await manager.walkthroughNext() } }
                                )
                            }
                        case .recap:
                            let score = Self.chapterScore(for: step, playback: playback)
                            WalkthroughRecapFace(claim: beat.text, remembered: score.remembered, asked: score.asked)
                        case .animation:
                            animationCard(step: step, playback: playback)
                        }
                    } else {
                        // A step with no words still takes one card: its title.
                        WalkthroughCardPoint(text: step.title)
                    }
                },
                chip: {
                    WalkthroughCardAnchorChip(
                        step: step,
                        resolved: resolved,
                        animationTitle: playback.animationRecord(for: step)?.title,
                        refocus: { Task { await manager.refocusWalkthroughStep(id: step.id, panel: nil) } }
                    )
                }
            )
            .task(id: step.id) {
                await manager.prepareCurrentWalkthroughCard()
            }
        }
    }

    /// The small line over the face: the step's title over a point, the
    /// question's kind over a question, the chapter's title over its recap.
    static func eyebrow(for beat: WalkthroughBeat?, step: PaperWalkthroughStep) -> String {
        switch beat?.kind {
        case .question: return step.quiz?.kind.label ?? "Question"
        case .recap: return beat?.context ?? "Chapter"
        case .point, .animation, nil: return step.title
        }
    }

    /// How the chapter a recap closes went: its questions, and how many the
    /// learner remembered or had right on the figure.
    static func chapterScore(for step: PaperWalkthroughStep, playback: ReviewSessionManager.WalkthroughPlayback) -> (remembered: Int, asked: Int) {
        guard let chapter = playback.walkthrough.chapter(ofStep: step.id) else { return (0, 0) }
        let quizSteps = playback.steps.filter { chapter.stepIDs.contains($0.id) && $0.quiz != nil }
        let remembered = quizSteps.filter { playback.recall[$0.id] == .remembered }.count
        return (remembered, quizSteps.count)
    }

    /// The step's animation, on its card: inline, or the saved animation
    /// pinned to the step — unless a pane in the window already shows that
    /// animation, which the step points at instead, and the card says so.
    @ViewBuilder
    private func animationCard(step: PaperWalkthroughStep, playback: ReviewSessionManager.WalkthroughPlayback) -> some View {
        if let html = step.animationHTML {
            WalkthroughAnimationCard(content: .inline(html: html)) {
                enlargeAnimation(WalkthroughEnlargedAnimation(id: step.id, title: step.title, content: .inline(html: html)))
            }
        } else if let reference = step.animation, let url = playback.animationPageURL(for: step) {
            if manager.walkthroughReaderShowsSource?(reference.animationID) ?? false {
                WalkthroughCardPoint(text: "The animation beside the chat is on this step.")
            } else {
                WalkthroughAnimationCard(content: .hosted(url: url)) {
                    enlargeAnimation(WalkthroughEnlargedAnimation(id: step.id, title: step.title, content: .hosted(url: url)))
                }
            }
        }
    }

    /// A point card's picture (`PaperWalkthrough.cardPicture(of:)`), no
    /// taller than `maxHeight`.
    @ViewBuilder
    private func cardPicture(
        step: PaperWalkthroughStep,
        playback: ReviewSessionManager.WalkthroughPlayback,
        resolved: WalkthroughResolvedAnchor?,
        record: PaperFigureRecord?,
        maxHeight: CGFloat
    ) -> some View {
        switch playback.walkthrough.cardPicture(of: step) {
        case .anchoredFigure:
            WalkthroughCardFigure(
                sourceID: playback.sourceID,
                resolved: resolved,
                caption: record.flatMap { PaperFigureCaptionTitle.title(from: $0.caption) } ?? step.anchor?.figureDisplayLabel,
                articleForSourceID: articleForSourceID,
                maxHeight: maxHeight
            )
        case .figure(let anchor):
            let pictureRecord = anchor.figureLabel.flatMap { playback.figureRecord(labelled: $0) }
            WalkthroughCardFigure(
                sourceID: playback.sourceID,
                resolved: manager.walkthroughCardPictureByStep[step.id],
                caption: pictureRecord.flatMap { PaperFigureCaptionTitle.title(from: $0.caption) } ?? anchor.figureDisplayLabel,
                articleForSourceID: articleForSourceID,
                maxHeight: maxHeight
            )
        case .drawn(let imageID, let brief):
            WalkthroughCardDrawnPicture(imageID: imageID, caption: brief, maxHeight: maxHeight)
        case nil:
            EmptyView()
        }
    }
}

#endif
