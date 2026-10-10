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

    static func selectionFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.13) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }

    static func selectionStroke(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.22) : .clear
    }
}

/// Native macOS sidebar tone for the custom, resizable navigation rail.
/// A custom rail is required by Studio's multi-pane layout, but its background
/// can still behave like a system sidebar across appearance and window focus.
///
/// The vibrancy blends *within* the window, over an opaque base. `.behindWindow`
/// samples the desktop instead, which is what let the wallpaper's gradient wash
/// through the rail while every other Studio panel painted flat
/// `windowBackgroundColor` — the rail read as a hole in the window rather than a
/// sidebar. Blending within the window keeps the sidebar's tint and its
/// active/inactive response with nothing behind it to show through.
struct StudioSidebarMaterial: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay { StudioSidebarVibrancy() }
    }
}

private struct StudioSidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
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
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StudioDesign.selectionStroke(isSelected: isSelected), lineWidth: 0.5)
            }
    }
}

// MARK: - Rail tooltip

/// The name an icon-only rail button shows under the pointer, drawn as Codex
/// draws it: a dark pill beside the button, after a short pause, nothing under
/// it but its name. AppKit's `.help` tooltip waits over a second, is a small
/// grey box and never appears at all while a drag is armed on the button, so
/// the icon strip used to be nameless (product owner, 2026-10-10: "these buttons …
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
        let size = hosting.fittingSize
        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchorRect.maxX, y: anchorRect.midY - size.height / 2)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(origin.x, visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
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
