import SwiftUI
#if os(iOS)
import UIKit
#endif

/// How a card looks wherever Memory draws one, on the Mac and on the phone
/// (docs/memory-design.md, "How a card looks", 2026-10-11): an index card —
/// paper, a hairline, a soft shadow, lifted a touch in dark mode — with the
/// question in the review's serif. What is left of a deal shows as the edges
/// of the cards under the one in front, so the deck thins as it is answered.
/// The words on a card are monochrome; colour is kept for the one state that
/// asks for something, a forgotten card (Review Forgotten). SwiftUI only, so
/// both apps draw the same card; each draws its own buttons (the Mac's
/// `MemoryReviewButton`, the phone's `MobileMemoryPillStyle`).
enum MemoryCardMetrics {
    static let cornerRadius: CGFloat = 16
    /// The question's size in the review's serif; the phone scales it with
    /// the reader's text size.
    static let frontSize: CGFloat = 24
    /// The answer's size.
    static let backSize: CGFloat = 18
    /// The question, large, in the review's serif.
    static let frontFont = Font.system(size: frontSize, weight: .regular, design: .serif)
    static let backFont = Font.system(size: backSize)
    /// A card in the review is never shorter than this, so a short question
    /// sits in the middle of a card rather than on a strip of one.
    static let cardMinimumHeight: CGFloat = 260
    #if os(iOS)
    /// The small tracked words over a question (NEW, TO CHECK): on the phone
    /// they scale with the text size, and take the secondary ink, which holds
    /// its contrast at that size on a phone's paper.
    static let tagFont = Font.caption2.weight(.semibold)
    /// Why the answer holds, under the answer: a size down from it, in the
    /// phone's text sizes.
    static let whyFont = Font.callout
    static let smallWordsStyle = HierarchicalShapeStyle.secondary
    #else
    static let tagFont = Font.system(size: 10, weight: .semibold)
    /// Why the answer holds, under the answer: a size down from it, close
    /// enough that it reads as the answer's next sentence.
    static let whyFont = Font.system(size: 15)
    static let smallWordsStyle = HierarchicalShapeStyle.tertiary
    #endif
}

extension Color {
    /// A card's paper: the Mac's control colour; the phone's grouped
    /// secondary background, white in light mode and a raised grey in dark.
    static var memoryCardPaper: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
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
                    .fill(Color.memoryCardPaper)
                    // In dark mode a touch of white lifts the card off the
                    // surface it lies on.
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
                    .fill(Color.memoryCardPaper)
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
/// "NEW", "TO CHECK" — in the card's own ink, never a colour.
struct MemoryCardTagLine: View {
    let tags: [String]

    var body: some View {
        Text(tags.joined(separator: " · ").uppercased())
            .font(MemoryCardMetrics.tagFont)
            .tracking(1)
            .foregroundStyle(MemoryCardMetrics.smallWordsStyle)
            .lineLimit(1)
            .textSelection(.disabled)
    }
}

/// Why the answer holds, as one more plain sentence under the answer: no
/// label, no rule, the card's secondary ink a size under the answer's. It
/// belongs to the answer rather than naming itself like a form field
/// (product owner, 2026-10-15, of the tiny WHY label beside it: "this why
/// also looks kind of weird"). VoiceOver still says what it is.
struct MemoryCardWhyLine: View {
    let why: [String]

    var body: some View {
        Text(why.joined(separator: " "))
            .font(MemoryCardMetrics.whyFont)
            .lineSpacing(2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityLabel("Why: " + why.joined(separator: " "))
    }
}

/// What the model made of the learner's answer, on the card under the fold
/// (docs/memory-design.md, "The answer is checked"): a short wait while it
/// checks, then the verdict in a word and its one line, or why there is no
/// verdict and the learner grades themselves. The grade buttons under the
/// card carry the verdict's suggestion; this line only says it.
struct MemoryCardVerdictLine: View {
    let check: MemoryCardSitting.AnswerCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch check {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Checking your answer\u{2026}")
                    .foregroundStyle(.secondary)
            case .judged(let result):
                Image(systemName: Self.symbol(result.verdict))
                    .foregroundStyle(result.verdict == .right ? Color.primary : Color.orange)
                    .accessibilityHidden(true)
                Text("\(Text(Self.word(result.verdict)).fontWeight(.semibold)) \(result.note)")
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let line):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.cards.verdict")
    }

    static func word(_ verdict: MemoryCardAnswerCheck.Verdict) -> String {
        switch verdict {
        case .right: return "Right."
        case .partly: return "Partly."
        case .wrong: return "Not quite."
        }
    }

    private static func symbol(_ verdict: MemoryCardAnswerCheck.Verdict) -> String {
        switch verdict {
        case .right: return "checkmark.circle"
        case .partly: return "circle.lefthalf.filled"
        case .wrong: return "xmark.circle"
        }
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
