import SwiftUI
import AppKit

/// Where the chrome over a pane's top-right corner goes, resolved once by
/// `StudioPaneHost` and handed to whatever the host draws there (the swap
/// control), so it and the pane's own close can never disagree.
struct StudioPaneHostCorner {
    let placement: StudioPaneClosePlacement
    /// How far the pane's laid-out content runs past what is visible.
    let trailingOverflow: CGFloat
    /// The pane close control's claim, immediately left of the restore
    /// control.
    let closeReservation: CGFloat
    /// Whether the pointer is over the pane, or was a moment ago: the swap
    /// control shows only then ("Quiet chrome", docs/ui-design.md).
    var isPointerOver = true
    /// For a corner control to report the pointer over itself, which sits in
    /// the titlebar band above the pane's own frame.
    var reportHover: (Bool) -> Void = { _ in }
    /// The titlebar band the corner's controls rise into, nil with none.
    var titlebarBandHeight: CGFloat?
    /// How the pane's swap control is drawn at this width, resolved with the
    /// close so the two share the corner without colliding.
    var swapTier: StudioPaneSwap.Tier = .none
}

/// The pane's own way to change what it shows, drawn over its top-right corner
/// beside its close (docs/ui-design.md, "Direct pane arrangement"): a row of
/// icons for the places that earn one, which fold into one menu button when the
/// pane is narrower, and leave the close alone when it is narrower still. What
/// the pane showed stays one of its tabs. The
/// product owner, 2026-10-15, of Codex's and Claude's right-hand panels:
/// "in codex they have buttons at the top right... same with claude... we could
/// also do a design like that". Dragging a sidebar row onto a pane does the
/// same job (`StudioPaneReplaceDropTarget`); this is the second way.
enum StudioPaneSwap {
    /// A place the control can show in its pane.
    struct Destination: Equatable {
        let tab: StudioCenterTab
        var startsBlankChat = false

        var title: String { tab.title }
        var systemImage: String { ShellPlaces.descriptor(for: tab).glyph }
        var dragPayload: StudioCenterTabDragPayload.Payload {
            .init(tab: tab, startsBlankChat: startsBlankChat)
        }

        /// Whether `current`, what the pane shows now, is this destination.
        func isShown(by current: StudioCenterTab) -> Bool {
            tab == current || (tab == .chat && current == .secondaryChat)
        }
    }

    enum Tier: Equatable {
        /// One icon per destination.
        case row
        /// One button that opens the destinations as a menu.
        case menu
        /// Nothing: the pane is too narrow to spare the room.
        case none
    }

    /// The visible widths at which the row, then the menu, fit beside the
    /// close and a title (a pane may be as narrow as 200pt).
    static let rowMinimumWidth: CGFloat = 520
    static let menuMinimumWidth: CGFloat = 300

    static let iconSize: CGFloat = StudioPanelChrome.centerTabCloseButtonSize
    /// Equal to twice the wash's reach past an icon, so neighbouring washes
    /// touch and their hit surfaces never overlap.
    static let iconSpacing: CGFloat = 4
    static let washInset: CGFloat = 2

    /// The five places a pane most often becomes, in the sidebar's order.
    static var centerDestinations: [Destination] {
        offered([.init(tab: .chat), .init(tab: .library), .init(tab: .memory), .init(tab: .browser), .init(tab: .notepad)])
    }

    /// What a pane's + offers as a new tab: the places a pane most often
    /// becomes, and the Space.
    static var newTabDestinations: [Destination] {
        offered(centerDestinations + [.init(tab: .artifacts)])
    }

    /// What a notebook's document slot can become. Chat is the notebook's own
    /// slot and the Library leaves the notebook, so neither is offered there.
    static var notebookDocumentDestinations: [Destination] {
        offered([.init(tab: .notepad), .init(tab: .browser), .init(tab: .memory)])
    }

    private static func offered(_ destinations: [Destination]) -> [Destination] {
        destinations.filter { !BetaFeatures.unofferedCenterTabs.contains($0.tab) }
    }

    static func tier(visibleWidth: CGFloat, destinationCount: Int) -> Tier {
        guard destinationCount > 0 else { return .none }
        if visibleWidth >= rowMinimumWidth { return .row }
        if visibleWidth >= menuMinimumWidth { return .menu }
        return .none
    }

    /// What the control claims at the corner, with the gap that separates it
    /// from the close.
    static func reservedWidth(tier: Tier, destinationCount: Int) -> CGFloat {
        switch tier {
        case .row:
            return CGFloat(destinationCount) * iconSize
                + CGFloat(max(0, destinationCount - 1)) * iconSpacing
                + StudioTopBar.paneControlSpacing
        case .menu:
            return iconSize + StudioTopBar.paneControlSpacing
        case .none:
            return 0
        }
    }
}

/// The swap control itself, laid over a pane's top-right corner by the host's
/// `corner` closure. It shows only while the pointer is over its pane, and every icon is also a drag source for the same destination.
struct StudioPaneSwapControl: View {
    let corner: StudioPaneHostCorner
    let destinations: [StudioPaneSwap.Destination]
    /// What the pane shows now: lit in the row, and a click on it does nothing.
    let current: StudioCenterTab
    let identifierPrefix: String
    let onSelect: (StudioPaneSwap.Destination) -> Void

    var body: some View {
        Group {
            switch corner.swapTier {
            case .row: row
            case .menu: menu
            case .none: EmptyView()
            }
        }
        .opacity(corner.isPointerOver ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: corner.isPointerOver)
        .padding(.trailing, StudioPanelChrome.headerHorizontalPadding
            + corner.trailingOverflow
            + corner.closeReservation)
        .frame(height: corner.titlebarBandHeight ?? StudioPanelChrome.headerHeight)
        .offset(y: corner.placement == .chromeLine ? -(corner.titlebarBandHeight ?? 0) : 0)
    }

    private var row: some View {
        HStack(spacing: StudioPaneSwap.iconSpacing) {
            ForEach(destinations, id: \.tab) { destination in
                let isShown = destination.isShown(by: current)
                TitlebarBandButton(
                    help: destination.title,
                    accessibilityLabel: destination.title,
                    accessibilityValue: isShown ? "Showing" : "",
                    accessibilityIdentifier: "\(identifierPrefix).swap.\(destination.tab.rawValue)",
                    washInset: StudioPaneSwap.washInset,
                    cornerRadius: 6,
                    onHover: corner.reportHover,
                    dragDestination: destination.dragPayload,
                    action: { if !isShown { onSelect(destination) } }
                ) {
                    Image(systemName: destination.systemImage)
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(isShown ? Color.primary : Color.secondary)
                        .frame(width: StudioPaneSwap.iconSize, height: StudioPaneSwap.iconSize)
                        .background(
                            StudioDesign.selectionFill(isSelected: isShown, isHovered: false),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
            }
        }
    }

    private var menu: some View {
        TitlebarBandButton(
            help: "Show in this pane",
            accessibilityLabel: "Show in this pane",
            accessibilityIdentifier: "\(identifierPrefix).swap.menu",
            washInset: StudioPaneSwap.washInset,
            cornerRadius: 6,
            onHover: corner.reportHover,
            action: {},
            menu: { [destinations, current, onSelect] in
                StudioPaneSwapMenu(destinations: destinations, current: current, onSelect: onSelect)
            }
        ) {
            Image(systemName: "rectangle.2.swap")
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }
}

/// The menu of destinations. It is its own item target, since a menu item
/// holds its target weakly and the menu outlives the press that built it.
final class StudioPaneSwapMenu: NSMenu {
    private let destinations: [StudioPaneSwap.Destination]
    private let onSelect: (StudioPaneSwap.Destination) -> Void

    init(
        destinations: [StudioPaneSwap.Destination],
        current: StudioCenterTab,
        onSelect: @escaping (StudioPaneSwap.Destination) -> Void
    ) {
        self.destinations = destinations
        self.onSelect = onSelect
        super.init(title: "")
        autoenablesItems = false
        for (index, destination) in destinations.enumerated() {
            let item = NSMenuItem(title: destination.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: destination.systemImage, accessibilityDescription: nil)
            item.state = destination.isShown(by: current) ? .on : .off
            addItem(item)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard destinations.indices.contains(sender.tag) else { return }
        onSelect(destinations[sender.tag])
    }
}

/// A hover that lingers: true as soon as the pointer is over any of its
/// sources, false a moment after it has left all of them. Quiet chrome that
/// appears under the pointer (a pane's swap control, a divider's swap) sits in the
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
                // line used by the pane's close and swap controls. Fullscreen has
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
/// overlays its top-right corner, and where the close goes. A pane's band
/// header, its × and its trailing reservations therefore work the same in
/// either shell.
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
    /// Whether the titlebar band passes through to the pane, which then
    /// raises its header into it. False only under a visible tab strip.
    var bandPassesThrough: Bool = true
    /// How many destinations the pane's swap control offers; zero for a pane
    /// that draws none. The host resolves its tier and reserves its room.
    var swapDestinationCount: Int = 0
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
        bandPassesThrough: Bool = true,
        swapDestinationCount: Int = 0,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder corner: @escaping (StudioPaneHostCorner) -> Corner,
        @ViewBuilder band: @escaping () -> Band
    ) {
        self.activeTab = activeTab
        self.width = width
        self.enclosingClip = enclosingClip
        self.leadingReservation = leadingReservation
        self.bandPassesThrough = bandPassesThrough
        self.swapDestinationCount = swapDestinationCount
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
        // One placement for the corner's controls, from the room the close
        // needs; each control reads it from the environment.
        let placement = StudioPaneClosePlacement.resolve(
            visibleWidth: visibleWidth,
            leadingReservation: leadingReservation,
            controlWidth: closeReservation
        )
        // The swap control draws only where it too keeps the controls on the
        // chrome line; otherwise the close keeps the corner to itself.
        var swapTier = bandPassesThrough
            ? StudioPaneSwap.tier(visibleWidth: visibleWidth, destinationCount: swapDestinationCount)
            : .none
        if swapTier != .none {
            let withSwap = StudioPaneClosePlacement.resolve(
                visibleWidth: visibleWidth,
                leadingReservation: leadingReservation,
                controlWidth: closeReservation
                    + StudioPaneSwap.reservedWidth(tier: swapTier, destinationCount: swapDestinationCount)
            )
            if placement != .chromeLine || withSwap != .chromeLine { swapTier = .none }
        }
        let pointer = pointer
        let corner = StudioPaneHostCorner(
            placement: placement,
            trailingOverflow: trailingOverflow,
            closeReservation: closeReservation,
            isPointerOver: pointer.isActive,
            reportHover: { pointer.set($0, from: "corner") },
            titlebarBandHeight: titlebarBandHeight,
            swapTier: swapTier
        )
        let swapReservation = StudioPaneSwap.reservedWidth(tier: swapTier, destinationCount: swapDestinationCount)
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
                    .environment(\.studioChromeLineReservation, chromeLineReservation(swapReservation: swapReservation))
                    .environment(\.studioPaneChromePlacement, placement)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Leading, not the default centre: a pane whose content
                    // needs more than it is given then runs over on its
                    // trailing side, under the clip below, and not equally to
                    // both sides, where the leading half was drawn over the
                    // sidebar beside the pane (the Library at 218pt beside a
                    // 200pt sidebar, 2026-10-28).
                    .frame(width: contentWidth, alignment: .leading)
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
    /// beside the code that draws it rather than in each pane: the close and
    /// the swap control ride over every pane that draws no strip.
    private func chromeLineReservation(swapReservation: CGFloat) -> StudioChromeLineReservation {
        var reservation = StudioChromeLineReservation()
        if bandPassesThrough {
            let drawsClose = StudioTopBar.paneDrawsCloseControl()
            reservation.paneControls = (drawsClose ? StudioTopBar.centerPaneCloseControlReservedWidth : 0)
                + swapReservation
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
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            activeTab: activeTab,
            width: width,
            enclosingClip: enclosingClip,
            leadingReservation: leadingReservation,
            content: content,
            corner: { _ in EmptyView() },
            band: { EmptyView() }
        )
    }
}

extension StudioPaneHost where Band == EmptyView {
    /// A pane with a corner control of its own and no strip: a notebook's
    /// document slot, which draws the swap control.
    init(
        activeTab: StudioCenterTab,
        width: CGFloat,
        enclosingClip: CGFloat = 0,
        leadingReservation: CGFloat = 0,
        swapDestinationCount: Int,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder corner: @escaping (StudioPaneHostCorner) -> Corner
    ) {
        self.init(
            activeTab: activeTab,
            width: width,
            enclosingClip: enclosingClip,
            leadingReservation: leadingReservation,
            swapDestinationCount: swapDestinationCount,
            content: content,
            corner: corner,
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

    /// The width the pane's close control claims at the corner, sized to
    /// whichever close the pane actually draws. The Reader owns a close even
    /// as the only pane, and a wider one than every other pane's.
    static func closeReservation(for tab: StudioCenterTab, bandPassesThrough: Bool) -> CGFloat {
        guard bandPassesThrough else { return 0 }
        if tab == .reader {
            return StudioTopBar.readerPaneCloseControlReservedWidth
        }
        return StudioTopBar.paneDrawsCloseControl() ? StudioTopBar.centerPaneCloseControlReservedWidth : 0
    }
}
