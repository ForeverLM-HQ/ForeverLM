import SwiftUI

/// Where the chrome over a pane's top-right corner goes, resolved once by
/// `StudioPaneHost` and handed to whatever the host draws there (a center
/// group's pin), so the pin and the pane's own close can never disagree.
struct StudioPaneHostCorner {
    let placement: StudioPaneClosePlacement
    /// How far the pane's laid-out content runs past what is visible.
    let trailingOverflow: CGFloat
    /// The pane close control's claim, immediately left of the restore
    /// control.
    let closeReservation: CGFloat
    /// Whether the pointer is over the pane, or was a moment ago: the pin
    /// shows only then ("Quiet chrome", docs/ui-design.md).
    var isPointerOver = true
    /// For a corner control to report the pointer over itself, which sits in
    /// the titlebar band above the pane's own frame.
    var reportHover: (Bool) -> Void = { _ in }
}

/// A hover that lingers: true as soon as the pointer is over any of its
/// sources, false a moment after it has left all of them. Quiet chrome that
/// appears under the pointer (a pane's pin, a divider's swap) sits in the
/// titlebar band above the frame that shows it, and the pointer crosses a
/// gap between the two on its way; without the linger the control would
/// vanish under it.
@Observable
@MainActor
final class StudioHoverLinger {
    private(set) var isActive = false
    @ObservationIgnored private var sources: Set<String> = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private let linger: Duration

    init(linger: Duration = .milliseconds(650)) {
        self.linger = linger
    }

    func set(_ isInside: Bool, from source: String) {
        if isInside { sources.insert(source) } else { sources.remove(source) }
        hideTask?.cancel()
        if !sources.isEmpty {
            if !isActive { isActive = true }
            return
        }
        let linger = linger
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }
}

/// The swap action on a divider between two panes, shown while the pointer is
/// over the divider or the button (docs/ui-design.md, "Direct pane
/// arrangement" and "Quiet chrome"). Until 2026-10-06 it was drawn on every
/// divider at all times. Apply after the divider's drag gesture, so the
/// button's press is a swap and not a drag.
struct StudioPaneSwapAffordance: ViewModifier {
    let titlebarBandHeight: CGFloat?
    let accessibilityIdentifier: String
    let action: () -> Void
    @State private var hover = StudioHoverLinger()

    func body(content: Content) -> some View {
        content
            .onHover { hover.set($0, from: "divider") }
            .overlay(alignment: .top) {
                TitlebarBandButton(
                    help: "Swap panes",
                    accessibilityLabel: "Swap panes",
                    accessibilityIdentifier: accessibilityIdentifier,
                    onHover: { hover.set($0, from: "button") },
                    action: action
                ) {
                    Image(systemName: "arrow.left.arrow.right")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    // Chrome only. Anything hit-testable above the band button
                    // takes its mouse-down back to the window drag.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .opacity(hover.isActive ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hover.isActive)
                // The divider starts below the hidden titlebar's safe area.
                // Lift its action into that band so it shares the exact chrome
                // line used by the pane pin and close controls. Fullscreen has
                // no titlebar band, so the same frame becomes its in-flow bar.
                .frame(height: titlebarBandHeight ?? StudioPanelChrome.headerHeight)
                .offset(y: -(titlebarBandHeight ?? 0))
            }
    }
}

/// The chrome every center pane gets from the column that holds it, for both
/// shells: a center group of the tab layout (`StudioCenterTabGroupsView`) and
/// a slot of the notebook workspace (`NotebookWorkspaceView`).
///
/// It lays the pane out at no less than its minimum width — clipped at the
/// column's real width, anchored leading, so a squeezed column never hands its
/// pane a degenerate proposal — and publishes what the pane's header and its
/// close × read: the titlebar band to rise into, the leading chrome to clear
/// (the traffic lights, for a pane at the window's leading edge), what
/// overlays its top-right corner, and where the close and pin go. A pane's
/// band header, its × and its trailing reservations therefore work the same
/// in either shell; a notebook slot simply draws no pin.
struct StudioPaneHost<Content: View, Corner: View, Band: View>: View {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight

    /// What the pane shows, which sets its minimum width and its close's.
    let activeTab: StudioCenterTab
    /// The column's width.
    let width: CGFloat
    /// How much of that column the enclosing column clips off its trailing
    /// edge (`StudioCenterTabGroupSizing.clippedTrailingWidth`); zero for a
    /// column fully on screen.
    var enclosingClip: CGFloat = 0
    /// The leading chrome this pane's header must clear: non-zero only for a
    /// pane at the window's leading edge while the navigation rail is hidden.
    var leadingReservation: CGFloat = 0
    /// Whether a pin shares the pane's corner with its close. Center groups
    /// draw one; a notebook slot never pins.
    var reservesPin: Bool = true
    /// Whether the titlebar band passes through to the pane, which then
    /// raises its header into it. False only under a visible tab strip.
    var bandPassesThrough: Bool = true
    @ViewBuilder let content: () -> Content
    /// Drawn over the pane's top-right corner, given where it goes.
    @ViewBuilder let corner: (StudioPaneHostCorner) -> Corner
    /// Drawn over the pane's top edge in the band (a visible tab strip).
    @ViewBuilder let band: () -> Band
    /// The pointer over the pane, for the quiet corner chrome.
    @State private var pointer = StudioHoverLinger()

    init(
        activeTab: StudioCenterTab,
        width: CGFloat,
        enclosingClip: CGFloat = 0,
        leadingReservation: CGFloat = 0,
        reservesPin: Bool = true,
        bandPassesThrough: Bool = true,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder corner: @escaping (StudioPaneHostCorner) -> Corner,
        @ViewBuilder band: @escaping () -> Band
    ) {
        self.activeTab = activeTab
        self.width = width
        self.enclosingClip = enclosingClip
        self.leadingReservation = leadingReservation
        self.reservesPin = reservesPin
        self.bandPassesThrough = bandPassesThrough
        self.content = content
        self.corner = corner
        self.band = band
    }

    var body: some View {
        let contentWidth = max(width, StudioPaneHostMetrics.minimumContentWidth(for: activeTab))
        // Everything trailing-anchored in the pane measures from these two
        // numbers: what the learner can see of it, and how far its laid out
        // content runs past that — its own overflow plus whatever the
        // enclosing column clips off this column in particular.
        let visibleWidth = max(0, width - enclosingClip)
        let trailingOverflow = enclosingClip + contentWidth - width
        let closeReservation = StudioPaneHostMetrics.closeReservation(
            for: activeTab,
            bandPassesThrough: bandPassesThrough
        )
        // One placement for the pin and the close alike, from the room both
        // need together; each control reads it from the environment.
        let placement = StudioPaneClosePlacement.resolve(
            visibleWidth: visibleWidth,
            leadingReservation: leadingReservation,
            controlWidth: (reservesPin ? StudioPanelChrome.centerTabCloseButtonSize : 0) + closeReservation
        )
        let pointer = pointer
        let corner = StudioPaneHostCorner(
            placement: placement,
            trailingOverflow: trailingOverflow,
            closeReservation: closeReservation,
            isPointerOver: pointer.isActive,
            reportHover: { pointer.set($0, from: "corner") }
        )
        return Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .onHover { pointer.set($0, from: "pane") }
            .overlay(alignment: .leading) {
                content()
                    // With the strip hidden the band passes through: the
                    // pane's header rises into the titlebar band and its
                    // in-flow row collapses. Only a pane at the window's
                    // leading edge sits under the traffic lights.
                    .environment(\.studioTitlebarBandHeight, bandPassesThrough ? titlebarBandHeight : nil)
                    .environment(\.studioCenterPaneHeaderLeadingInset, bandPassesThrough ? leadingReservation : 0)
                    .environment(\.studioCenterTabStripVisible, !bandPassesThrough)
                    .environment(\.studioChromeLineReservation, chromeLineReservation())
                    .environment(\.studioPaneChromePlacement, placement)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity)
                    // The pane lives inside the outer center column; both may
                    // be clipped at once, so its own overflow rides on top of
                    // the part of the outer clip that reaches it.
                    .environment(\.studioPanelTrailingOverflow, trailingOverflow)
                    .overlay(alignment: .topTrailing) {
                        if placement != .hidden {
                            self.corner(corner)
                        }
                    }
                    .overlay(alignment: .top) {
                        band()
                    }
            }
            .clipShape(StudioPanelColumnClipShape())
            .allowsHitTesting(width > 1)
    }

    /// What the chrome over this pane's top-right corner claims, resolved
    /// beside the code that draws it rather than in each pane: the pin and
    /// the close ride over every pane once the strip is hidden.
    private func chromeLineReservation() -> StudioChromeLineReservation {
        var reservation = StudioChromeLineReservation()
        if bandPassesThrough {
            let drawsClose = StudioTopBar.paneDrawsCloseControl()
            reservation.paneControls = (reservesPin ? StudioTopBar.centerPanePinControlReservedWidth : 0)
                + (drawsClose ? StudioTopBar.centerPaneCloseControlReservedWidth : 0)
        }
        return reservation
    }
}

extension StudioPaneHost where Corner == EmptyView, Band == EmptyView {
    /// A pane with nothing of the host's own over its corner: a notebook
    /// slot, whose only corner control is the pane's own close.
    init(
        activeTab: StudioCenterTab,
        width: CGFloat,
        enclosingClip: CGFloat = 0,
        leadingReservation: CGFloat = 0,
        reservesPin: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            activeTab: activeTab,
            width: width,
            enclosingClip: enclosingClip,
            leadingReservation: leadingReservation,
            reservesPin: reservesPin,
            content: content,
            corner: { _ in EmptyView() },
            band: { EmptyView() }
        )
    }
}

/// The widths a pane host works from, shared by both shells.
enum StudioPaneHostMetrics {
    /// A chat needs a chat's width; every other pane the ordinary minimum.
    static func minimumContentWidth(for tab: StudioCenterTab) -> CGFloat {
        [.chat, .secondaryChat].contains(tab)
            ? StudioCenterTabGroupSizing.minimumChatContentWidth
            : StudioCenterTabGroupSizing.minimumContentWidth
    }

    /// The width the pane's close control claims immediately to the pin's
    /// right, sized to whichever close the pane actually draws. The Reader
    /// owns a close even as the only pane, and a wider one than every other
    /// pane's; keep the pin one control-slot to its left there too.
    static func closeReservation(for tab: StudioCenterTab, bandPassesThrough: Bool) -> CGFloat {
        guard bandPassesThrough else { return 0 }
        if tab == .reader {
            return StudioTopBar.readerPaneCloseControlReservedWidth
        }
        return StudioTopBar.paneDrawsCloseControl() ? StudioTopBar.centerPaneCloseControlReservedWidth : 0
    }
}
