// The chat header control button and the composer chip button and chip.
import SwiftUI
import AppKit

/// A chat header's trailing control, which works in the titlebar band too
/// (`TitlebarBandButton` there, a hover-washed button in flow): the memory
/// focus chrome's × (`MemoryReviewFocusChrome`).
///
/// Docked, the header hangs in the window's titlebar band, where a SwiftUI
/// `Button` lights up under the pointer but loses its click to the window
/// drag as soon as the pointer moves a pixel between press and release (see
/// `TitlebarBandHitSurfaceView`). The `WindowDragBlocker` under the row does
/// not stop that — the Reader's toolbar gave up the same blocker for the
/// same reason — so in the band this is a `TitlebarBandButton` that owns its
/// press. The pop-out window and fullscreen keep a plain `Button` with the
/// same round wash.
struct ChatHeaderControlButton<Label: View>: View {
    let onTitlebarBand: Bool
    let controlSize: CGFloat
    let help: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    /// How far the wash and the click target reach past the icon's square, the
    /// same on both paths so the control looks and hits identically wherever
    /// the header is mounted.
    private let washInset: CGFloat = 5

    var body: some View {
        if onTitlebarBand {
            TitlebarBandButton(
                help: help,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                washInset: washInset,
                controlSize: controlSize,
                // The in-flow wash is a circle; a radius of half the grown
                // target keeps it one here.
                cornerRadius: (controlSize + washInset * 2) / 2,
                action: action,
                label: label
            )
        } else {
            Button(action: action) {
                label()
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: -washInset, opacity: 0.12))
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

/// The composer's notebook chip, as a button or as the picker's menu: the
/// label with a capsule wash on hover and press. `.menuStyle(.button)` lets
/// a button style draw a Menu's label (`PickerPillButtonStyle`). The canvas's
/// "+N" chip wears it too (`KnowledgeMapChatChipRow`).
struct ComposerChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ComposerChip(isPressed: configuration.isPressed, content: configuration.label)
    }
}

private struct ComposerChip<Content: View>: View {
    let isPressed: Bool
    let content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.primary.opacity(isPressed ? 0.09 : (isHovering ? 0.06 : 0)))
            )
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
