import SwiftUI

/// How a card looks wherever Memory draws one (docs/memory-design.md, "How a
/// card looks", 2026-10-11): an index card — the control colour, a hairline,
/// a soft shadow, lifted a touch in dark mode — with the question in the
/// review's serif. What is left of a deal shows as the edges of the cards
/// under the one in front, so the deck thins as it is answered. The words on
/// a card are monochrome; colour is kept for the one state that asks for
/// something, a forgotten card (Review Forgotten). The review's buttons are
/// the Space's: a dark pill for the one that moves on, a pale one beside it,
/// and the key that presses each drawn as a key.
enum MemoryCardMetrics {
    static let cornerRadius: CGFloat = 16
    /// The question, large, in the review's serif.
    static let frontFont = Font.system(size: 24, weight: .regular, design: .serif)
    static let backFont = Font.system(size: 18)
    /// The answer buttons' height, Show Answer's included.
    static let buttonHeight: CGFloat = 38
}

extension View {
    /// A card's paper. `raised` is the card in front of the learner (the
    /// review's); a card in a list lies flatter.
    func memoryCardSurface(cornerRadius: CGFloat = MemoryCardMetrics.cornerRadius, raised: Bool = true) -> some View {
        modifier(MemoryCardSurface(cornerRadius: cornerRadius, raised: raised))
    }
}

private struct MemoryCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let raised: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    // In dark mode the control colour is the pane's own; a
                    // touch of white lifts the card off it.
                    .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0)))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                    .shadow(color: .black.opacity(raised ? 0.08 : 0.03), radius: raised ? 20 : 5, y: raised ? 10 : 2)
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// The cards under the one in front: an edge below it for each card still
/// to come, up to two. Drawn behind a card (`.background`), it reaches
/// `depth` points under the card's frame, which the caller leaves room for.
struct MemoryDeckEdges: View {
    /// How many cards wait under the one in front.
    let remaining: Int
    var cornerRadius: CGFloat = MemoryCardMetrics.cornerRadius

    @Environment(\.colorScheme) private var colorScheme

    /// How far the deepest edge shows under the card.
    static let depth: CGFloat = 14

    var body: some View {
        let layers = min(max(remaining, 0), 2)
        ZStack(alignment: .bottom) {
            // The deepest first, so the nearer edge is drawn over it.
            ForEach(Array((0..<layers).reversed()), id: \.self) { index in
                let step = CGFloat(index + 1)
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.03 : 0)))
                    .overlay(shape.fill(Color.primary.opacity(0.012 * step)))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
                    .padding(.horizontal, 12 * step)
                    .offset(y: Self.depth / 2 * step)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: layers)
        .accessibilityHidden(true)
    }
}

/// What kind of card this is, in a few small words above its question —
/// "NEW · MEDIUM", "TO CHECK" — in the card's own ink, never a colour.
struct MemoryCardTagLine: View {
    let tags: [String]

    var body: some View {
        Text(tags.joined(separator: " · ").uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .textSelection(.disabled)
    }
}

/// "WHY", small, beside why the answer holds.
struct MemoryCardWhyLine: View {
    let why: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("WHY")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(why.joined(separator: " "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Why: " + why.joined(separator: " "))
        }
        .textSelection(.disabled)
    }
}

/// Where a card folds between its question and its answer: a dashed hairline.
struct MemoryCardFold: View {
    var body: some View {
        HorizontalHairline()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .foregroundStyle(Color.primary.opacity(0.16))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct HorizontalHairline: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// A key, drawn as a key: what presses the button it sits in. For the eye
/// only; VoiceOver hears the button's title.
struct MemoryKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(.tertiary, lineWidth: 1))
            .textSelection(.disabled)
            .accessibilityHidden(true)
    }
}

/// The review's buttons. `primary` is the Space's dark pill, for the one
/// that moves on (Show Answer, Remembered, Done); `secondary` a pale pill
/// beside it (Forgot, Review Forgotten); `quiet` no pill at all (Go Deeper,
/// Skip, Practice). Each may draw the key that presses it. The pills paint
/// their own hover, as the dark pill does: a wash behind a filled pill
/// would not show.
struct MemoryReviewButton: View {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    let title: String
    var key: String? = nil
    var kind: Kind = .secondary
    var minWidth: CGFloat = 0
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        switch kind {
        case .primary:
            Button(action: action) {
                label(height: MemoryCardMetrics.buttonHeight)
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .background(Capsule().fill(Color.primary.opacity(isHovering && isEnabled ? 0.78 : 0.9)))
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcut)
            .ownsRowHoverWash()
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
        case .secondary:
            Button(action: action) {
                label(height: MemoryCardMetrics.buttonHeight)
                    .foregroundStyle(.primary)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(Capsule().fill(Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0)))
                    )
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcut)
            .ownsRowHoverWash()
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
        case .quiet:
            Button(action: action) {
                label(height: 30)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.07))
            .keyboardShortcut(shortcut)
            .accessibilityLabel(title)
        }
    }

    private func label(height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
            if let key {
                MemoryKeycap(key: key)
            }
        }
        .font(.system(size: kind == .quiet ? 12.5 : 13.5, weight: .medium))
        .padding(.horizontal, kind == .quiet ? 12 : 18)
        .frame(minWidth: minWidth, minHeight: height)
        .contentShape(Capsule())
        .textSelection(.disabled)
    }
}

/// A round a card at a time: a segment a card, filled as it is answered, a
/// forgotten card's in orange — the state Review Forgotten acts on — and the
/// card in front marked. A deal too long for segments is one bar.
struct MemoryRoundStrip: View {
    enum Mark: Equatable {
        case upcoming
        case current
        case remembered
        case forgot
        /// A card to check skipped in Practice: passed, never answered.
        case skipped
    }

    let marks: [Mark]
    var height: CGFloat = 4

    /// The most cards drawn as segments.
    private static let segmentLimit = 60

    var body: some View {
        Group {
            if marks.count > Self.segmentLimit {
                bar
            } else {
                HStack(spacing: marks.count > 30 ? 1.5 : 3) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        Capsule()
                            .fill(Self.fill(mark))
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: marks)
        .accessibilityHidden(true)
    }

    /// One bar: answered as far as the round has gone.
    private var bar: some View {
        let done = marks.filter { $0 != .upcoming && $0 != .current }.count
        let fraction = marks.isEmpty ? 1 : CGFloat(done) / CGFloat(marks.count)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Self.fill(.upcoming))
                Capsule()
                    .fill(Self.fill(.remembered))
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }

    static func fill(_ mark: Mark) -> Color {
        switch mark {
        case .upcoming: return Color.primary.opacity(0.09)
        case .current: return Color.primary.opacity(0.32)
        case .remembered: return Color.primary.opacity(0.72)
        case .forgot: return Color.orange.opacity(0.8)
        case .skipped: return Color.primary.opacity(0.2)
        }
    }

    /// A sitting's round as marks: answered cards by their answer, a card
    /// passed with no answer skipped, the card in front current.
    static func marks(of sitting: MemoryCardSitting) -> [Mark] {
        sitting.cards.enumerated().map { index, card in
            if let remembered = sitting.results[card.itemID] { return remembered ? .remembered : .forgot }
            if index < sitting.position { return .skipped }
            return index == sitting.position ? .current : .upcoming
        }
    }
}

/// The answered card leaving: tossed off toward the side its answer's key
/// points (← Forgot, → Remembered), tipping as it goes.
struct MemoryCardToss: ViewModifier {
    let offset: CGFloat
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .offset(x: offset)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// A card coming off the deck and going to one side once answered; with
    /// Reduce Motion, a fade.
    static func memoryCard(leavingTo edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let sign: CGFloat = edge == .trailing ? 1 : -1
        return .asymmetric(
            insertion: .scale(scale: 0.97, anchor: .bottom).combined(with: .opacity),
            removal: .modifier(
                active: MemoryCardToss(offset: sign * 360, angle: Double(sign) * 7, opacity: 0),
                identity: MemoryCardToss(offset: 0, angle: 0, opacity: 1)
            )
        )
    }
}
