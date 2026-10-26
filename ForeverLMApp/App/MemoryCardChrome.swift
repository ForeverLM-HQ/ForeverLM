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

// MARK: - Editing a card

/// A card being edited, drawn as the card it is: the question in the review's
/// serif, the fold, the answer, why it holds, each a quiet field you type straight into
/// (a soft wash under the one with the keys), then Cancel and one dark pill.
/// The triage sheet and a kept card's sheet share it, so both read as the card
/// they change rather than a form about it.
struct MemoryCardEditorForm: View {
    @Binding var front: String
    @Binding var back: String
    @Binding var why: String
    /// The pictures on each side, shown as the review shows them. They are not
    /// edited here: the edit carries them through unchanged.
    var frontImages: [MemoryCardImage] = []
    var backImages: [MemoryCardImage] = []
    /// What the pill says: Keep for a draft, Save for a kept card.
    let primaryTitle: String
    let canSave: Bool
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryCardTagLine(tags: ["Edit card"])
                .padding(.bottom, 12)
            MemoryCardEditorField(
                text: $front, prompt: "The question", font: MemoryCardMetrics.frontFont, label: "Front",
                identifier: "memory.card.editor.front"
            )
            if !frontImages.isEmpty {
                MemoryCardImageGrid(images: frontImages, animationStartsAtOnce: false)
                    .padding(.top, 8)
            }
            MemoryCardFold()
                .padding(.vertical, 12)
            MemoryCardEditorField(
                text: $back, prompt: "The answer", font: MemoryCardMetrics.backFont, label: "Back",
                identifier: "memory.card.editor.back"
            )
            if !backImages.isEmpty {
                MemoryCardImageGrid(images: backImages, animationStartsAtOnce: false)
                    .padding(.vertical, 8)
            }
            MemoryCardEditorField(
                text: $why, prompt: "Why the answer holds", font: MemoryCardMetrics.whyFont, label: "Why",
                identifier: "memory.card.editor.why"
            )
            .foregroundStyle(.secondary)
            // The fields' own insets already leave a gap under the answer.
            .padding(.top, -4)
            HStack(spacing: 8) {
                Spacer()
                MemoryReviewButton(title: "Cancel", kind: .quiet, shortcut: .cancelAction, action: cancel)
                MemoryReviewButton(title: primaryTitle, kind: .primary, minWidth: 96, shortcut: .defaultAction, action: save)
                    .disabled(!canSave)
            }
            .padding(.top, 24)
        }
        .textSelection(.disabled)
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 560)
    }
}

/// One of the card's lines to type into: no box, the text of the card in the
/// card's own type. It grows with what is typed (a hidden copy of the text
/// sets its height under the editor), and a wash appears under the pointer
/// and under the line that has the keys.
private struct MemoryCardEditorField: View {
    @Binding var text: String
    let prompt: String
    let font: Font
    let label: String
    let identifier: String

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The height of the editor: the text, laid out the same way.
            Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
                .font(font)
                .lineSpacing(2)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .opacity(0)
                .accessibilityHidden(true)
            TextEditor(text: $text)
                .font(font)
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($focused)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            if text.isEmpty {
                Text(prompt)
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.05 : hovering ? 0.03 : 0))
        )
        // The editor's own inset and the wash's reach come out of the margin,
        // so the text stands where the card's text does.
        .padding(.horizontal, -11)
        .onHover { hovering = $0 }
    }
}
