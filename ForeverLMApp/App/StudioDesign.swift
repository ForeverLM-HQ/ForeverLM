import AppKit
import SwiftUI

/// Shared visual foundations for the macOS shell.
///
/// These values intentionally stay small and semantic. The app should get most
/// of its appearance from SwiftUI/AppKit controls and system materials; this
/// layer only keeps custom Studio chrome on one spacing and selection rhythm.
enum StudioDesign {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 7
        static let surface: CGFloat = 10
    }

    enum Metrics {
        /// Compact enough for a Mac sidebar, but tall enough to preserve text
        /// when the app-level type-size preference is increased.
        static let navigationRowMinHeight: CGFloat = 32
        static let chromeButtonWidth: CGFloat = 30
        static let chromeButtonHeight: CGFloat = 28
        /// The width one source-type tab wants before its icon starts scaling
        /// down to keep the whole strip on screen.
        static let comfortableSourceTabWidth: CGFloat = 26
        /// The horizontal margin of a pane's page: Docs, Sites and
        /// Animations, a notebook's Tasks board and its Files.
        static let pageMargin: CGFloat = 24
    }

    /// A selected row or icon is a step of grey, as in Codex and the Space's
    /// sidebar (`SpaceSidebarMetrics.selectedFill`), never a tint of the
    /// accent: the blue wash and its outline on the icon strip read as a
    /// stray colour beside Codex's chrome (product owner, 2026-10-12: "this
    /// top left still looks a bit bad with colors; make it look more like
    /// codex"). 5% is Codex's own step, measured off its window the same day
    /// (#E5E4E5 on its #F1F1F0 strip, #EDEDED on its #FAFAFA sidebar). A
    /// hover is under half of it: at 3.5% the row under the pointer read as
    /// a second selection beside the selected one (product owner,
    /// 2026-10-12, of Pages and Sites both grey in the Space sidebar).
    static func selectionFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.primary.opacity(0.05) }
        if isHovered { return Color.primary.opacity(0.02) }
        return .clear
    }
}

/// One icon-button treatment for controls that share the macOS titlebar band.
/// The label is deliberately monochrome; accent color remains reserved for
/// selection, status, and a primary next action.
struct StudioChromeIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(isActive ? Color.primary : (isHovered ? Color.primary : Color.secondary))
                .frame(
                    width: StudioDesign.Metrics.chromeButtonWidth,
                    height: StudioDesign.Metrics.chromeButtonHeight
                )
                .background(
                    RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                        .fill(StudioDesign.selectionFill(isSelected: isActive, isHovered: isHovered))
                )
                .contentShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { isHovered = $0 }
    }
}

/// Consistent selected/hover surface for custom navigation rows and tabs.
struct StudioSelectionBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = StudioDesign.Radius.control

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(StudioDesign.selectionFill(isSelected: isSelected, isHovered: isHovered))
    }
}

// MARK: - Rail tooltip

/// The name an icon-only rail button shows under the pointer, drawn as Codex
/// draws it: a dark pill beside the button, after a short pause, nothing under
/// it but its name. AppKit's `.help` tooltip waits over a second, is a small
/// grey box and never appears at all while a drag is armed on the button, so
/// the icon strip would be nameless (product owner, 2026-10-10: "these buttons …
/// should have like a name when you hover over them").
///
/// It lives in its own borderless panel so it floats over the content card,
/// which is drawn after the rail and would hide an overlay.
extension View {
    /// Replaces `.help` on a rail icon: the pill carries the name.
    func railTooltip(_ text: String) -> some View {
        modifier(RailTooltipModifier(text: text))
    }
}

/// `.help` where the control is a labelled row, the pill where it is the
/// icon strip's glyph alone.
struct RailHelpOrTooltip: ViewModifier {
    let text: String
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCompact {
            content.railTooltip(text)
        } else {
            content.help(text)
        }
    }
}

private struct RailTooltipModifier: ViewModifier {
    let text: String
    @State private var anchor = RailTooltipAnchor()

    func body(content: Content) -> some View {
        anchor.text = text
        return content
            .background(RailTooltipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside {
                    anchor.scheduleShow()
                } else {
                    anchor.hide()
                }
            }
            .onDisappear { anchor.hide() }
    }
}

@MainActor
private final class RailTooltipAnchor {
    weak var view: NSView?
    var text = ""
    private var showTask: Task<Void, Never>?

    func scheduleShow() {
        showTask?.cancel()
        // Moving along the strip names the next icon at once, as Codex does.
        let delay: Duration = RailTooltipPanel.shared.wasVisibleRecently ? .milliseconds(40) : .milliseconds(450)
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let view = self.view, !self.text.isEmpty else { return }
            RailTooltipPanel.shared.show(text: self.text, beside: view)
        }
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        RailTooltipPanel.shared.hide()
    }
}

private struct RailTooltipAnchorView: NSViewRepresentable {
    let anchor: RailTooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

@MainActor
private final class RailTooltipPanel {
    static let shared = RailTooltipPanel()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var lastHiddenAt = Date.distantPast

    var wasVisibleRecently: Bool {
        panel?.isVisible == true || Date().timeIntervalSince(lastHiddenAt) < 0.6
    }

    func show(text: String, beside view: NSView) {
        guard let window = view.window, window.isVisible, NSApp.isActive else { return }
        let hosting = NSHostingView(rootView: RailTooltipPill(text: text))
        let fitting = hosting.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        // Measured once; after that the pill never sizes its panel. As the
        // panel's content view with the default sizing options, the hosting
        // view pinned the panel's min and max size to SwiftUI's on every
        // constraints pass, and when the two disagreed each pass resized the
        // panel and asked for another, until AppKit ended the app (build 210,
        // 2026-10-11: clicking the calendar glyph quit ForeverLM). So the
        // hosting view sits inside a plain view and sizes nothing.
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchorRect.maxX, y: anchorRect.midY - size.height / 2)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(origin.x, visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = container
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        installDismissMonitor()
    }

    func hide() {
        if panel?.isVisible == true { lastHiddenAt = Date() }
        panel?.orderOut(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// A click, a key or a scroll puts the pill away at once; the pointer
    /// leaving does the rest.
    private func installDismissMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
    }
}

private struct RailTooltipPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            // Its own size whatever the panel's, so it never truncates.
            .fixedSize()
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.09))
            )
            .padding(6)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}

// MARK: - Chat chrome (chat-chrome-kit begin)

/// The chat's chrome, Codex's (product owner, 2026-10-11: "make the chat
/// experience more look chatgpt codex. you can basically steal the entire
/// design"), measured off the ChatGPT app's own stylesheet: the composer a
/// solid card with a hairline and a soft shadow, what the chat works in on a
/// grey tray tucked behind the card's top edge, dark send and stop circles,
/// and the learner's messages as a light grey pill at most 70% of the column
/// wide. The replies' typography is the shared renderer's (`chat-render.css`).
extension StudioDesign {
    enum Chat {
        /// Codex's composer corners (`--composer-border-radius`, 7 spacing units).
        static let composerCornerRadius: CGFloat = 24
        /// The tray's top corners, a step inside the card's.
        static let trayCornerRadius: CGFloat = 18
        /// How far in from the card's sides the tray stands.
        static let trayInset: CGFloat = 7
        /// How far the tray runs under the card, so its square foot never shows
        /// past the card's rounded top corners.
        static let trayTuck: CGFloat = 12
        /// Send and Stop, the composer's trailing circle.
        static let actionDiameter: CGFloat = 28
        /// A learner message takes at most this share of the column
        /// (`--user-chat-width`).
        static let userMessageWidthFraction: CGFloat = 0.7
        /// The learner's pill (`--radius-2xl`, 5.5 spacing units).
        static let userBubbleCornerRadius: CGFloat = 22

        /// White in light, the elevated grey in dark (`--color-background-composer-surface`).
        static let composerFill = dynamic(light: NSColor.white, dark: NSColor(white: 0.2, alpha: 1))
        /// The card's edge: a 4% ring in light, a 20% inner glow in dark
        /// (`--elevation-composer`, `--elevation-composer-dark`). A touch
        /// stronger here, since a Mac pane is not always white behind it.
        static let composerHairline = dynamic(
            light: NSColor(white: 0, alpha: 0.08),
            dark: NSColor(white: 1, alpha: 0.12)
        )
        /// The card's two soft shadows; none in dark, as Codex draws none.
        static let composerShadow = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: .clear)
        static let composerAmbientShadow = dynamic(light: NSColor(white: 0, alpha: 0.03), dark: .clear)
        /// The tray behind the card: the pane's ground a step darker in light,
        /// a step lighter in dark.
        static let trayFill = dynamic(
            light: NSColor(white: 0, alpha: 0.045),
            dark: NSColor(white: 1, alpha: 0.045)
        )
        /// Send and Stop: full ink, the glyph in the ground's colour.
        static let actionFill = dynamic(light: NSColor(white: 0.05, alpha: 1), dark: NSColor(white: 0.96, alpha: 1))
        static let actionGlyph = dynamic(light: NSColor.white, dark: NSColor(white: 0.08, alpha: 1))
        /// The learner's pill (`--color-background-user-message`, 5% of the
        /// text colour; Codex's compact pill is #f3f3f3 / #414141).
        static let userBubbleFill = dynamic(
            light: NSColor(white: 0, alpha: 0.05),
            dark: NSColor(white: 1, alpha: 0.10)
        )

        /// A colour that resolves per appearance at draw time; a plain
        /// `Color(white:)` stays light in a dark window.
        private static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }
}

extension View {
    /// The composer's card: solid, hairline-edged, softly shadowed. Drops and
    /// clicks still reach the content; the edge is drawn over it untouchable.
    func chatComposerCard(cornerRadius: CGFloat = StudioDesign.Chat.composerCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(StudioDesign.Chat.composerFill)
                .shadow(color: StudioDesign.Chat.composerShadow, radius: 4, x: 0, y: 2)
                .shadow(color: StudioDesign.Chat.composerAmbientShadow, radius: 20, x: 0, y: 4)
        }
        .overlay {
            shape
                .strokeBorder(StudioDesign.Chat.composerHairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// The composer with what the chat works in on a grey tray behind its top
/// edge, as Codex shows the project and the machine there. The card is drawn
/// last, so it sits over the tray's foot. With nothing to show the tray is not
/// drawn and the card stands alone.
struct ChatComposerStack<Tray: View, Card: View>: View {
    let showsTray: Bool
    @ViewBuilder let tray: () -> Tray
    @ViewBuilder let card: () -> Card

    var body: some View {
        VStack(spacing: 0) {
            if showsTray {
                tray()
                    .padding(.horizontal, StudioDesign.Spacing.small)
                    .padding(.top, 6)
                    .padding(.bottom, 6 + StudioDesign.Chat.trayTuck)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        StudioDesign.Chat.trayFill,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: StudioDesign.Chat.trayCornerRadius,
                            topTrailingRadius: StudioDesign.Chat.trayCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, StudioDesign.Chat.trayInset)
                    .padding(.bottom, -StudioDesign.Chat.trayTuck)
                    .transition(.opacity)
            }
            card()
        }
    }
}

/// Send's and Stop's face: a glyph on a full-ink circle.
struct ChatComposerActionCircle: View {
    let systemImage: String
    var glyphSize: CGFloat = 12
    var isEnabled = true

    var body: some View {
        Image(systemName: systemImage)
            .zoomedSystemFont(size: glyphSize, weight: .bold)
            .foregroundStyle(StudioDesign.Chat.actionGlyph)
            .frame(width: StudioDesign.Chat.actionDiameter, height: StudioDesign.Chat.actionDiameter)
            .background(StudioDesign.Chat.actionFill.opacity(isEnabled ? 1 : 0.22), in: Circle())
            .contentShape(Circle())
    }
}

/// A learner message's column: the message is offered at most
/// `userMessageWidthFraction` of the row (and never more than `maxWidth`), and
/// sits against the row's trailing edge at the width its words need.
struct ChatUserMessageColumn: Layout {
    var maxWidth: CGFloat = .infinity
    var fraction: CGFloat = StudioDesign.Chat.userMessageWidthFraction

    private func childWidth(for rowWidth: CGFloat?) -> CGFloat? {
        guard let rowWidth, rowWidth.isFinite else { return maxWidth.isFinite ? maxWidth : nil }
        return min(maxWidth, (rowWidth * fraction).rounded(.down))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: childWidth(for: proposal.width), height: nil))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? size.width
        return CGSize(width: max(width, size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let offered = ProposedViewSize(width: childWidth(for: bounds.width), height: nil)
        let size = child.sizeThatFits(offered)
        child.place(
            at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}

// MARK: chat-chrome-kit end
