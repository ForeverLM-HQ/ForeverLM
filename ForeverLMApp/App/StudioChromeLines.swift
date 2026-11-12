// The window chrome view, chrome line dividers and the pane environment keys.

import SwiftUI
import AppKit

/// Applies the chrome as soon as the view lands in a window, keeps the traffic
/// lights centered in the visual top bar, and stays out of hit testing so the
/// band above the panels keeps dragging the window.
final class StudioWindowChromeView: NSView {
    private var lightObservers: [NSObjectProtocol] = []
    private var measuredTopSafeAreaInset: CGFloat = 0
    private var bandCheckScheduled = false
    private var bandCheckAttempts = 0
    private var didNudgeForBand = false

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI lays the whole window out against the top safe-area inset it
    /// last measured, and every header that shares the titlebar band is placed
    /// from that same number. The band, though, only ever changes underneath
    /// SwiftUI: handing the window its toolbar grows it from 32pt to 52pt after
    /// the first layout, and fullscreen takes it away again. The re-measure that
    /// should follow usually lands within a frame — but it is not guaranteed,
    /// and when it goes missing the whole top bar is drawn 20pt too high,
    /// underneath the band, with the panels' first rows clipped by the same
    /// amount. That is the empty top bar people see at launch, and why resizing
    /// the window has always fixed it: a resize is the re-measure SwiftUI
    /// skipped. So force it here instead of waiting to be resized.
    func reconcileBand(measuredBy inset: CGFloat) {
        measuredTopSafeAreaInset = inset
        guard let window else { return }
        guard !bandMatchesMeasurement(in: window) else {
            didNudgeForBand = false
            return
        }
        scheduleBandCheck()
    }

    /// The band AppKit actually reserves above the content, against what
    /// SwiftUI last measured. A window mid-transition reports no band at all;
    /// treat that as agreement rather than something to correct.
    private func bandMatchesMeasurement(in window: NSWindow) -> Bool {
        let band = window.frame.height - window.contentLayoutRect.height
        guard band > 0 else { return true }
        return abs(band - measuredTopSafeAreaInset) <= 0.5
    }

    /// Give SwiftUI a second to notice the band on its own before correcting
    /// it: a disagreement is normal for a frame or two after the toolbar lands,
    /// and a window that resizes itself the moment anything is briefly out of
    /// step would be worse than the bug. One correction per disagreement — if
    /// the nudge does not take, nudging again will not help either.
    private func scheduleBandCheck() {
        guard !bandCheckScheduled, !didNudgeForBand else { return }
        bandCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.correctStaleBandIfNeeded() }
        }
    }

    private func correctStaleBandIfNeeded() {
        bandCheckScheduled = false
        guard let window else { return }
        // Fullscreen has no band to match: AppKit keeps the toolbar and paints
        // an opaque titlebar backdrop over the band, so the toolbar has to go
        // for the in-content layout to engage. Re-apply that here, since a
        // window restored straight into fullscreen can enter it before this
        // view is in the window to hear `willEnterFullScreen`.
        guard !window.styleMask.contains(.fullScreen) else {
            window.toolbar?.isVisible = false
            return
        }
        guard !bandMatchesMeasurement(in: window) else {
            bandCheckAttempts = 0
            return
        }
        bandCheckAttempts += 1
        guard bandCheckAttempts >= 4 else {
            scheduleBandCheck()
            return
        }
        didNudgeForBand = true
        // The window's own size is the one input every layout in it is derived
        // from, so changing it and putting it straight back is what makes
        // SwiftUI measure the band again — the same repair the learner has been
        // making by hand, a second after launch and a point wide.
        let frame = window.frame
        window.setFrame(frame.insetBy(dx: 0, dy: -1), display: false)
        window.setFrame(frame, display: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingLights()
        guard let window else { return }
        StudioWindowChrome.installTopBar(in: window)
        observeLights(in: window)
        recenterLights(in: window)
        window.toolbar?.isVisible = !window.styleMask.contains(.fullScreen)
        // Installing the toolbar is itself a band change SwiftUI has to notice,
        // and nothing here guarantees another `updateNSView` to ask from.
        scheduleBandCheck()
    }

    deinit {
        for observer in lightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static let lightButtons: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton,
    ]

    /// AppKit resets the buttons to its own placement whenever the window
    /// lays out its titlebar (resize, tab changes, fullscreen round-trips), so
    /// watch their frames and re-apply. Setting a frame re-fires the
    /// notification, but the already-at-target guard keeps that from looping.
    /// Fullscreen exit can rebuild the buttons entirely, which would strand the
    /// old observers — reinstall everything when it happens.
    private func observeLights(in window: NSWindow) {
        for type in Self.lightButtons {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            lightObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                MainActor.assumeIsolated { self.recenterLights(in: window) }
            })
        }
        lightObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            MainActor.assumeIsolated {
                self.stopObservingLights()
                self.observeLights(in: window)
                self.recenterLights(in: window)
            }
        })
        // In fullscreen AppKit keeps the (empty) unified toolbar on screen and
        // paints an opaque titlebar backdrop over the band, hiding every header
        // the panels hang up into it — while the top safe-area inset stays at
        // its 52pt windowed value, so the in-content fallback layout never
        // engages either: the whole top bar reads as lost. Hiding the toolbar
        // for the duration of fullscreen collapses the inset to zero, which
        // flips all band-dependent chrome to its in-content layout.
        lightObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated { window?.toolbar?.isVisible = false }
        })
        lightObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated { window?.toolbar?.isVisible = true }
        })
    }

    private func stopObservingLights() {
        for observer in lightObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lightObservers = []
    }

    /// A no-op while `extraBandHeight` is zero: the target matches AppKit's
    /// own centering, and the guard skips the move.
    private func recenterLights(in window: NSWindow) {
        // In fullscreen the buttons live in the auto-revealed menu bar strip;
        // leave them to AppKit (there is no visual band to center in anyway).
        guard !window.styleMask.contains(.fullScreen) else { return }
        for type in Self.lightButtons {
            guard let button = window.standardWindowButton(type),
                  let titlebar = button.superview,
                  titlebar.frame.height >= 20 else { continue }
            let visualBand = titlebar.frame.height + StudioTopBar.extraBandHeight
            // Non-flipped titlebar view: y is measured from its bottom edge.
            let targetY = (titlebar.frame.height - visualBand / 2 - button.frame.height / 2).rounded()
            if abs(button.frame.origin.y - targetY) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
            }
        }
    }
}

extension View {
    /// - Parameter containsRow: Pass `true` for a full header row, which is
    ///   then kept inside its pane's strip of the band
    ///   (`studioChromeLineRowContainment`). Leave it off for a single control
    ///   that its caller positions itself, such as a close target: filling the
    ///   width would move the control to the center of the row.
    func studioPanelHeaderChrome(
        horizontalPadding: CGFloat = StudioPanelChrome.headerHorizontalPadding,
        height: CGFloat = StudioPanelChrome.headerHeight,
        extraLeadingPadding: CGFloat = 0,
        containsRow: Bool = false
    ) -> some View {
        // The row's own gutter goes inside the containment so an edge control's
        // hover wash has the gutter to draw into rather than the clip edge.
        self
            .padding(.horizontal, horizontalPadding)
            .modifier(StudioChromeLineRowContainmentIfNeeded(isEnabled: containsRow))
            .padding(.leading, extraLeadingPadding)
            .frame(height: height, alignment: .center)
    }
}

private struct StudioChromeLineRowContainmentIfNeeded: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.studioChromeLineRowContainment()
        } else {
            content
        }
    }
}

extension View {

    /// Puts one header row on the window's chrome line — the line the traffic
    /// lights and the navigation rail's sidebar toggle share — and keeps the
    /// pane's content clear of it.
    ///
    /// Docked in a window the row hangs in the titlebar band and the in-flow
    /// copy collapses, handing the row's height back to content. Full screen
    /// has no band, so the row takes the shared in-flow header height. This is
    /// the part a pane must not derive by hand: a row placed with `.padding(.top,` some number `)` sits below the
    /// band instead of in it, and lands a few points off the toggle even in
    /// full screen.
    ///
    /// overlay + offset, never `.ignoresSafeArea`: on macOS 26 a
    /// safe-area-ignoring subtree stops painting its SwiftUI-drawn content in
    /// the band (the reader title went invisible; same failure as the source
    /// tab bar, see StudioSidebar).
    ///
    /// The row's own horizontal padding and any `WindowDragBlocker` stay with
    /// the caller — only the pane knows where its controls actually sit, and
    /// backing a full-width row would leave AppKit no draggable titlebar at
    /// all. Clearance for chrome the pane does not lay out is *not* the
    /// caller's job: this modifier insets the row past the traffic
    /// lights/sidebar toggle on the leading side and past whatever
    /// `StudioChromeLineReservation` says overlays the pane's top-right corner
    /// on the trailing side. Panes kept re-deriving both by hand and kept
    /// forgetting one (the Notebooks gallery ran its New notebook button
    /// underneath the Sources restore toggle).
    /// In the band the row always stands on the band's chrome, across the
    /// whole pane — the leading traffic-light/toggle inset and the trailing
    /// reservation included — so a pane's background and its scrolled content
    /// never show there (`StudioBandRow`). A pane that painted a backing itself
    /// could only cover its own controls, and its content still showed through
    /// the reserved corners (the planner's grey day cards slid under the pin
    /// and close buttons). `opaque` backs the in-flow row of a window with no
    /// band (fullscreen) the same way, in the pane's color. Backing is a color
    /// only: dragging the titlebar still works, since `WindowDragBlocker` is
    /// what takes that away.
    func studioChromeLineHeader<Header: View>(
        opaque: Bool = false,
        @ViewBuilder _ header: () -> Header
    ) -> some View {
        modifier(StudioChromeLineHeader(isOpaque: opaque, header: header()))
    }

    /// A pane whose chrome line holds only its name: the name, where no tab
    /// names the pane. Under a strip whose tab already says it the row is
    /// not drawn at all, and the pane's content starts at its top.
    func studioPaneNameHeader(_ name: String) -> some View {
        modifier(StudioChromeLineHeader(
            isOpaque: false,
            yieldsToTab: true,
            header: StudioPaneNameRow(name: name)
        ))
    }

    /// Keeps a close affordance on center surfaces when the shared tab strip is
    /// hidden. With the strip visible, it owns the close button for every pane.
    /// Both affordances close the whole pane, preserving the adjacent pane's
    /// active surface while parking this pane's tabs beside it — and when this
    /// is the only pane, they reveal Chat in place rather than disappearing and
    /// leaving the surface no way out.
    func studioCenterTabCloseChrome(for tab: StudioCenterTab) -> some View {
        modifier(StudioCenterTabCloseChrome(tab: tab, close: nil))
    }
}

/// The hairline between two columns of the card: the column's full height,
/// and in the titlebar band a short stroke centered on the chrome line, the
/// way Codex divides its sidebar's line from the thread's title. Run up to the
/// window's top edge, as it was while the card filled the band, it would cross
/// the band's chrome and the card's top edge. Drawn with an overlay and an
/// offset, as the chrome line itself is, never `.ignoresSafeArea` (see
/// `studioChromeLineHeader`).
struct StudioColumnHairline: View {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    var color = Color(nsColor: .separatorColor)

    /// Codex's stroke is 20pt of its 44pt band.
    static let bandStrokeHeight: CGFloat = 20

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .overlay(alignment: .top) {
                if let band = titlebarBandHeight {
                    Rectangle()
                        .fill(color)
                        .frame(width: 1, height: Self.bandStrokeHeight)
                        .offset(y: -(band + Self.bandStrokeHeight) / 2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The short stroke between two columns' chrome lines where both columns are
/// one pane (the Space's sidebar and its list), whose band the pane's own
/// header backs: drawn in the header row, where the pane's backing cannot
/// cover it.
///
/// With no band (full screen) the row is in flow at the card's top and the
/// sidebar's tone runs up beside it (`SpaceSidebarHeader`), so the stroke runs
/// the row's full height and joins the column's divider below it.
struct StudioChromeLineDivider: View {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: titlebarBandHeight == nil ? .infinity : StudioColumnHairline.bandStrokeHeight)
            .accessibilityHidden(true)
    }
}

/// A pane's name on its chrome line (`studioPaneNameHeader`).
private struct StudioPaneNameRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .textSelection(.disabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }
}

private struct StudioCenterTabCloseChrome: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterTabStripVisible) private var centerTabStripVisible
    @Environment(\.studioPanelTrailingOverflow) private var trailingOverflow
    @Environment(\.studioChromeLineReservation) private var chromeReservation
    @Environment(\.studioPaneChromePlacement) private var placement

    let tab: StudioCenterTab?
    /// What × does for a pane with no tab; nil closes `tab`'s surface.
    let close: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay {
                // The placement is the group's, resolved once beside the swap
                // control that shares this corner, so the two can never split between
                // the chrome line and the content row.
                if !centerTabStripVisible && drawsCloseControl && placement != .hidden {
                    GeometryReader { proxy in
                        PaneCloseButton(action: closePane)
                            .studioPanelHeaderChrome(
                                height: titlebarBandHeight ?? StudioPanelChrome.headerHeight
                            )
                            .offset(
                                x: -trailingOverflow,
                                y: placement == .chromeLine ? -(titlebarBandHeight ?? 0) : 0
                            )
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height,
                                alignment: .topTrailing
                            )
                    }
                }
            }
    }

    private var drawsCloseControl: Bool {
        StudioTopBar.paneDrawsCloseControl()
    }

    /// Closes the whole pane while there is a neighbour to park these tabs in,
    /// and otherwise — this being the only pane — reveals Chat in place. Either
    /// way the surface the learner asked to dismiss goes away.
    private func closePane() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if let close {
                close()
            } else if let tab {
                vm.dismissCenterSurface(tab, in: windowState)
            }
        }
    }
}

/// Height of the visual top bar a panel header may rise into: the hidden
/// titlebar band (the window's top safe-area inset) plus
/// `StudioTopBar.extraBandHeight` of content below it. `nil` when there is no
/// band to rise into (fullscreen, the pop-out reader window, or a pane docked
/// under a visible center tab strip — the strip owns the band then) — headers
/// then use their regular in-content chrome. Hiding the tab bar passes the
/// band back through to the panes.
private struct StudioTitlebarBandHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

/// Extra leading padding for the active center pane's top row while it sits in
/// the titlebar band, so Reader, Notebooks, Schedule, and their detail views all
/// clear the traffic lights and persistent toggles when the navigation rail and
/// center tab strip are hidden.
private struct StudioCenterPaneHeaderLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Whether a center pane currently has a visible tab strip above it. The strip
/// owns the pane-level close action while present; hidden strips hand that
/// action back to each pane's compact header.
private struct StudioCenterTabStripVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

/// The tab whose name the strip over this pane shows, nil where no strip is
/// drawn. A pane never repeats that name under it: `SpacePlaceTitle` and
/// `studioPaneNameHeader` give way to it (product owner, 2026-11-07: "There
/// is already text like library in that tab… not sure we also need like
/// library underneath there as a title").
private struct StudioPaneTabKey: EnvironmentKey {
    static let defaultValue: StudioCenterTab? = nil
}

/// True inside a row that hangs in the window's titlebar band. Shared toolbar
/// controls read it to render as a `TitlebarBandButton` rather than a SwiftUI
/// `Button`: in the band a `Button` neither lights up under the pointer nor
/// receives its mouse-down (see `TitlebarBandHitSurfaceView`), while the same
/// control in an in-flow toolbar or an `NSToolbar` works as a plain `Button`.
private struct StudioTitlebarBandControlsKey: EnvironmentKey {
    static let defaultValue = false
}

/// What the chrome overlaying this pane's top-right corner claims on the
/// window's chrome line: the Sources restore control while the Sources panel
/// is collapsed, and the pane close target while the center tab strip is
/// hidden. Published once per center group, read by every header row that sits
/// on that line, so the controls and the rows never overlap.
private struct StudioChromeLineReservationKey: EnvironmentKey {
    static let defaultValue = StudioChromeLineReservation()
}

/// Where the pane's close and swap controls go — resolved once per center group
/// from the pane's *visible* width, and read by every control that shares the
/// line so none of them can reach a different answer.
private struct StudioPaneChromePlacementKey: EnvironmentKey {
    static let defaultValue = StudioPaneClosePlacement.chromeLine
}

/// Accumulated points that enclosing panel layouts clip off this content's
/// trailing edge.
///
/// Columns lay their content out at `minimumContentWidth` but clip at the
/// column's real width, anchored leading, so a column dragged narrower than its
/// minimum hides the right side of its own content. Nested layouts add their
/// overflow to the inherited value. Trailing-anchored chrome (and the adaptive
/// reader toolbar) reads the total so it stays inside the visible edge instead
/// of being clipped away and made unhittable.
private struct StudioPanelTrailingOverflowKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// The pane (`StudioCenterTabGroups.Group.id`) a surface is drawn in; nil
/// outside the tab layout, a notebook's slots included.
private struct StudioPaneGroupIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

/// Whether the tab a surface is drawn for is the one its pane shows. False
/// only for a tab kept mounted behind another (`StudioKeptPaneTabs`).
private struct StudioPaneTabIsShownKey: EnvironmentKey {
    static let defaultValue = true
}

/// The places a pane keeps mounted, hidden, while another of its tabs shows,
/// so coming back to one is instant. Pages first (product owner, 2026-11-08:
/// "if i go from pages to space and then back to pages; pages has to reload
/// for quite a bit"): rebuilt, it re-read the library, re-asked the published
/// statuses, re-read the page from disk and sent it to a fresh editor. A
/// place joins once it is safe hidden: no work that must stop when it is not
/// seen, and every AppKit view it hosts hiding itself and giving up the key
/// focus (`StudioKeptPaneTabs.apply`).
enum StudioKeptPaneTabs {
    static let places: Set<StudioCenterTab> = [.notepad]

    /// Hides an AppKit view of a kept tab while its tab is behind another,
    /// and takes the keyboard from it: an invisible web view holding the
    /// first responder would take the typing meant for the tab in front.
    @MainActor
    static func apply(isShown: Bool, to view: NSView) {
        let hidden = !isShown
        guard view.isHidden != hidden else { return }
        if hidden, let window = view.window,
           let responder = window.firstResponder as? NSView,
           responder === view || responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        view.isHidden = hidden
    }
}

/// A pane tab kept mounted behind the one in front: not drawn, not hit, not
/// read by VoiceOver, and its controls' keyboard shortcuts off.
struct StudioKeptPaneTabVisibility: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
            .zIndex(isShown ? 1 : 0)
    }
}

extension EnvironmentValues {
    var studioTitlebarBandHeight: CGFloat? {
        get { self[StudioTitlebarBandHeightKey.self] }
        set { self[StudioTitlebarBandHeightKey.self] = newValue }
    }

    var studioPanelTrailingOverflow: CGFloat {
        get { self[StudioPanelTrailingOverflowKey.self] }
        set { self[StudioPanelTrailingOverflowKey.self] = newValue }
    }

    /// Which pane a request aimed at one copy of a place reaches
    /// (`ArtifactRevealRequest.groupID`).
    var studioPaneGroupID: UUID? {
        get { self[StudioPaneGroupIDKey.self] }
        set { self[StudioPaneGroupIDKey.self] = newValue }
    }

    /// False while this surface's tab is kept mounted behind another tab of
    /// its pane (`StudioKeptPaneTabs`): what it shows is not on screen.
    var studioPaneTabIsShown: Bool {
        get { self[StudioPaneTabIsShownKey.self] }
        set { self[StudioPaneTabIsShownKey.self] = newValue }
    }

    var studioCenterPaneHeaderLeadingInset: CGFloat {
        get { self[StudioCenterPaneHeaderLeadingInsetKey.self] }
        set { self[StudioCenterPaneHeaderLeadingInsetKey.self] = newValue }
    }

    var studioCenterTabStripVisible: Bool {
        get { self[StudioCenterTabStripVisibleKey.self] }
        set { self[StudioCenterTabStripVisibleKey.self] = newValue }
    }

    var studioPaneTab: StudioCenterTab? {
        get { self[StudioPaneTabKey.self] }
        set { self[StudioPaneTabKey.self] = newValue }
    }

    var studioTitlebarBandControls: Bool {
        get { self[StudioTitlebarBandControlsKey.self] }
        set { self[StudioTitlebarBandControlsKey.self] = newValue }
    }

    var studioChromeLineReservation: StudioChromeLineReservation {
        get { self[StudioChromeLineReservationKey.self] }
        set { self[StudioChromeLineReservationKey.self] = newValue }
    }
    var studioPaneChromePlacement: StudioPaneClosePlacement {
        get { self[StudioPaneChromePlacementKey.self] }
        set { self[StudioPaneChromePlacementKey.self] = newValue }
    }
}

/// The × that closes a pane, on the titlebar's chrome line.
struct PaneCloseButton: View {
    let action: () -> Void

    var body: some View {
        // A `Button` on the chrome line hands its mouse-down to the titlebar's
        // window drag; see `TitlebarBandHitSurfaceView`.
        TitlebarBandButton(
            help: "Close pane",
            accessibilityLabel: "Close pane",
            action: action
        ) {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(
                    width: StudioPanelChrome.centerTabCloseButtonSize,
                    height: StudioPanelChrome.centerTabCloseButtonSize
                )
        }
    }
}
