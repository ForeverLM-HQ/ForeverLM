import SwiftUI

/// The Mac's half of how a card looks (docs/memory-design.md, "How a card
/// looks", 2026-10-11). The card itself — its paper, the deck's edges, the
/// fold, the tag and why lines, the round's strip and the toss — is shared
/// with the phone (`Shared/Views/MemoryCardDeck.swift`). Here are the
/// review's buttons, the Space's: a dark pill for the one that moves on, a
/// pale one beside it, and the key that presses each drawn as a key.
extension MemoryCardMetrics {
    /// The answer buttons' height, Show Answer's included.
    static let buttonHeight: CGFloat = 38
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
