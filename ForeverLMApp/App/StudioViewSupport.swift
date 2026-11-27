import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit
import OSLog

let supportedBookImportContentTypes: [UTType] = [
    .pdf, .epub, .kindleAZW, .kindleAZW3, .kindleMOBI, .kindlePRC
]

let supportedBookImportDropTypes: [UTType] = [.fileURL] + supportedBookImportContentTypes
let mcpSourceContextDropTypes: [UTType] = [.studioSourceID, .studioArticle, .studioGroup]

/// Whether the interaction being handled carries a multi-selection modifier:
/// shift extends a range and command toggles a row, as in every macOS list.
///
/// Reads the event being dispatched when there is one, because a List
/// selection binding and a row gesture both run synchronously inside AppKit's
/// handling of the click that caused them; the live keyboard state is the
/// fallback for writes that arrive under no event.
func isSourceMultiSelectModifierActive() -> Bool {
    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    return flags.contains(.shift) || flags.contains(.command)
}

enum SourceTabBarLayout: String, CaseIterable, Hashable {
    case compact
    case roomy

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .roomy: return "Roomy"
        }
    }

    var description: String {
        switch self {
        case .compact:
            return "Keep source types in one narrow row."
        case .roomy:
            return "Show source types across two rows with larger icons."
        }
    }
}

enum SourceTabIconSize: String, CaseIterable, Hashable {
    case small
    case medium
    case large

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Multiplier applied to the sidebar tab glyphs and the tab bar height.
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.25
        }
    }
}

/// Clips a panel column horizontally and at the bottom like `.clipped()`, but
/// leaves headroom above the top edge so the reader header can rise into the
/// hidden-titlebar band without being cut off.
struct StudioPanelColumnClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 60, width: rect.width, height: rect.height + 60))
    }
}

/// Clips a chrome-line header row horizontally only, to the strip of the band
/// that belongs to its pane. Vertical room is left generous so hover washes
/// and popover anchors that reach above or below the row are untouched.
struct StudioChromeLineRowClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 60, width: rect.width, height: rect.height + 120))
    }
}

extension View {
    /// Keeps a header row inside its pane's strip of the chrome line.
    ///
    /// The rows that share the titlebar band are plain `HStack`s. Proposed less
    /// width than their fixed controls need — the leftmost pane dragged to its
    /// minimum with the navigation rail hidden, say — an `HStack` does not
    /// truncate; it reports its full size and its parent centers it, so the
    /// row spills equally to both sides: leading, over the traffic lights and
    /// sidebar toggle it was inset to clear, and trailing, into the next pane.
    /// Filling the proposal and clipping to it turns that spill into a cut
    /// at the strip's edges instead. A row that fits is left exactly as it was.
    func studioChromeLineRowContainment() -> some View {
        self
            .frame(maxWidth: .infinity)
            .clipShape(StudioChromeLineRowClipShape())
    }
}

enum StudioPanelChrome {
    static let headerHeight: CGFloat = 54
    static let headerHorizontalPadding: CGFloat = 16
    /// Shared target widths for the close controls that occupy a center pane's
    /// trailing chrome.
    static let centerTabCloseButtonSize: CGFloat = 22
    static let readerCloseButtonSize: CGFloat = 26
}

/// Where a center pane's trailing chrome — the close target and swap control
/// drawn over its top-right corner — may go, given how much of the pane is
/// actually on screen.
///
/// Center-pane content is deliberately allowed to keep a usable logical width
/// while its viewport is clipped, so the controls are anchored to the visible
/// edge rather than the layout edge. Without an explicit collision test,
/// shifting them back to that edge can carry them underneath the traffic
/// lights and the sidebar toggle on the shared chrome line. The rule is
/// resolved once per pane (`StudioCenterTabGroupsView`) and published through
/// `\.studioPaneChromePlacement`, so every control on the line reads the same
/// answer: two controls that each did their own arithmetic once disagreed,
/// and one of them stayed on the line while the other dropped.
enum StudioPaneClosePlacement: Equatable {
    /// On the traffic lights' center line, in the titlebar band.
    case chromeLine
    /// Below the band, on the pane's first content row, because the visible
    /// pane is too narrow for the controls to clear the window's leading chrome.
    case contentTop
    /// Not drawn: the visible pane cannot even hold the controls, so anywhere
    /// they landed would be over a neighbour or outside the pane.
    case hidden

    static let interControlSpacing: CGFloat = 12

    static func resolve(
        visibleWidth: CGFloat,
        leadingReservation: CGFloat,
        controlWidth: CGFloat,
        horizontalPadding: CGFloat = StudioPanelChrome.headerHorizontalPadding
    ) -> Self {
        let controlsLeftEdge = visibleWidth
            - horizontalPadding
            - controlWidth
        guard controlsLeftEdge >= 0 else { return .hidden }
        // A pane with no leading reservation cannot collide with window-level
        // leading chrome; leave its controls on the shared line.
        guard leadingReservation > 0 else { return .chromeLine }
        return controlsLeftEdge >= leadingReservation + interControlSpacing
            ? .chromeLine
            : .contentTop
    }
}

/// Keeps a chat header's column-bound content clear of whatever claims the
/// panel's trailing edge.
///
/// The header's title is laid out on the transcript's reading column, so where
/// it ends follows the pane's width rather than the edge it has to respect —
/// the copy button anchored to the panel's trailing edge, and behind that the
/// pane's close and swap control drawn over its top-right corner. On a pane only a
/// little wider than the column the two overlap. Nothing laid out in the
/// header row can move an overlay, so the column-bound content gives way
/// instead, and only by as much as it has to: a column that already ends left
/// of the reserved line gives up nothing.
enum StudioChatHeaderClearance {
    /// Extra trailing padding the column-bound content needs, in the panel's
    /// own coordinates.
    ///
    /// - Parameters:
    ///   - panelWidth: Width of the chat panel — the pane less whatever its
    ///     host insets it by.
    ///   - gutter: The header row's own horizontal padding.
    ///   - columnMaxWidth: Cap on the reading column's width.
    ///   - chromeClearance: How far in from the panel's trailing edge the
    ///     column-bound content must stop. Zero when nothing is reserved
    ///     there.
    static func extraTrailingPadding(
        panelWidth: CGFloat,
        gutter: CGFloat,
        columnMaxWidth: CGFloat,
        chromeClearance: CGFloat
    ) -> CGFloat {
        guard chromeClearance > 0, panelWidth > 0 else { return 0 }
        // The column is centered in what the gutters leave, so its own trailing
        // edge sits a gutter plus half the leftover width in from the panel.
        let available = max(0, panelWidth - gutter * 2)
        let columnWidth = min(columnMaxWidth, available)
        let columnTrailingGap = gutter + (available - columnWidth) / 2
        return max(0, chromeClearance - columnTrailingGap)
    }

    /// Extra leading padding the column-bound content needs to start clear of
    /// the window's own controls — ‹ › and the sidebar toggle — drawn over the
    /// leftmost pane's top-left corner. The column is centered, so on a wide
    /// pane its leading edge already sits right of them and this is zero.
    ///
    /// `chromeClearance` is how far in from the panel's leading edge the
    /// content must start; the arithmetic is `extraTrailingPadding`'s, mirrored.
    static func extraLeadingPadding(
        panelWidth: CGFloat,
        gutter: CGFloat,
        columnMaxWidth: CGFloat,
        chromeClearance: CGFloat
    ) -> CGFloat {
        extraTrailingPadding(
            panelWidth: panelWidth,
            gutter: gutter,
            columnMaxWidth: columnMaxWidth,
            chromeClearance: chromeClearance
        )
    }

    /// Where the header's own trailing control stops, measured in from the
    /// panel's trailing edge.
    ///
    /// The control is anchored to the panel rather than to the reading column,
    /// so it sits with the pane's other controls at every width instead of
    /// drifting inward as the column narrows. Docked, `chromeClearance` is
    /// already the line one shared control gap left of the pane's controls, so the
    /// control lands beside it; undocked there is no such chrome and the
    /// header's own gutter is the whole of it.
    static func controlTrailingInset(gutter: CGFloat, chromeClearance: CGFloat) -> CGFloat {
        max(gutter, chromeClearance)
    }

    /// How far in from the panel's trailing edge the column-bound title has to
    /// stop: clear of the trailing control, with the shared control gap
    /// between them. Feed this to `extraTrailingPadding(…)` as the clearance
    /// the column must respect.
    static func titleClearance(
        gutter: CGFloat,
        chromeClearance: CGFloat,
        controlSize: CGFloat,
        controlGap: CGFloat = StudioPaneClosePlacement.interControlSpacing
    ) -> CGFloat {
        controlTrailingInset(gutter: gutter, chromeClearance: chromeClearance)
            + controlSize
            + controlGap
    }
}

/// Metrics for the chrome that shares the titlebar band with the traffic
/// lights. The bar is close kin to the Codex desktop app's (measured over the
/// Accessibility API: 46pt, lights centered): AppKit's unified toolbar makes a
/// 52pt band with the lights centered and comfortably inset for free.
enum StudioTopBar {
    /// How far the visual top bar extends below the AppKit titlebar band (the
    /// top safe-area inset, ~52pt with the unified toolbar). Zero means the bar
    /// IS the band; raising this makes headers claim content below the band and
    /// StudioWindowChrome re-centers the traffic lights in the taller bar.
    /// Large changes failed twice: shrinking the band itself
    /// (bare titlebar, 46pt) left the sources tab row blank on macOS 26, and
    /// extending the bar to 60pt (+8) shifted the lights off the
    /// sidebar toggle's line and read as dead air around them. The 52pt band
    /// with AppKit's own light centering was the known-good configuration.
    ///
    /// 2pt (2026-11-11, product owner: "when the app is not in full screen
    /// mode, this tab bar at the top is a little bit too narrow"): windowed,
    /// the band is AppKit's 52pt while full screen draws
    /// `StudioPanelChrome.headerHeight` (54pt), so +2 makes the two match.
    /// Not seen in the app yet: if the lights sit off the toggle's line, this
    /// is the one constant to move.
    ///
    /// 6pt (2026-11-15, product owner: "this top tab is a bit too narrow;
    /// make it taller ... when not in full screen mode"): the 2pt was still
    /// short, so the windowed band is 58pt. +8 was the earlier failure; stay
    /// under it. Not seen in the app yet.
    static let extraBandHeight: CGFloat = 6
    /// The offset that hangs a row of height `band` (`studioTitlebarBandHeight`)
    /// in the visual top bar from the top of the content, which starts at the
    /// AppKit band's bottom edge. The row spans the band plus the extra below
    /// it, so it reaches up only `band - extraBandHeight`; lifting it the full
    /// `band` put its center `extraBandHeight` above the traffic lights' line
    /// (the tab row stood about 5pt above the toggles and the lights).
    static func hangOffset(band: CGFloat) -> CGFloat { -(band - extraBandHeight) }
    /// Left edge of the window's own controls beside the lights, Codex's:
    /// ‹ › and the sidebar toggle, 30pt each (~92→186pt).
    static let leadingControlsLeading: CGFloat = 92
    /// The gap between those controls.
    static let leadingControlsSpacing: CGFloat = 2
    /// How wide they run: ‹, › and the toggle.
    static let leadingControlsWidth = 3 * StudioDesign.Metrics.chromeButtonWidth + 2 * leadingControlsSpacing
    /// What a notebook window's Studio toggle adds to those controls.
    static let notebookStudioToggleClearance = StudioDesign.Metrics.chromeButtonWidth + leadingControlsSpacing
    /// Gap between the controls drawn over a pane's top-right corner: its
    /// swap control, its close target and a header's own trailing controls.
    static let paneControlSpacing: CGFloat = 12
    /// What the active center pane's close target claims at the top-right,
    /// with the same gap. The target is drawn as an overlay on
    /// top of the pane, so nothing in a pane's own header row can push it
    /// aside — a header with trailing controls of its own reserves this much
    /// instead, or the two draw in the same place.
    static let centerPaneCloseControlReservedWidth =
        StudioPanelChrome.centerTabCloseButtonSize + paneControlSpacing
    /// The same claim for a pane whose close target is Reader's own, which is
    /// the larger of the two close controls. Reserving the shared width for it
    /// left its hover wash — and so its hit surface — 2pt inside its neighbour's.
    static let readerPaneCloseControlReservedWidth =
        StudioPanelChrome.readerCloseButtonSize + paneControlSpacing
    static let centerTabStripHorizontalPadding: CGFloat = 10

    /// Whether the pane showing `activeTab` draws a close target while the
    /// center tab strip is hidden — the one rule every pane's chrome and every
    /// reservation is measured from, so a control and the space kept for it can
    /// never disagree.
    ///
    /// Every pane draws its close, including a lone one: the product owner's rule is that
    /// the × in the top right is always there. A lone workspace surface closes
    /// onto Chat, and a lone Chat closes onto the Reader beside it in the same
    /// pane, so no surface is a dead end.
    ///
    /// A review that has taken the window over draws no pane close at all, only
    /// its own ×: the pane it sits in is the whole center while it lasts, so
    /// closing it would rearrange the workspace the review promises to hand
    /// back unchanged — and drawn there, the control landed on the header's
    /// copy button.
    static func paneDrawsCloseControl(memoryReviewFocused: Bool = false) -> Bool {
        !memoryReviewFocused
    }

    /// Left edge of the leftmost panel's in-band header, so its title clears the
    /// lights, ‹ › and the sidebar toggle and stands a short step after them, as
    /// Codex's thread title does after its arrows (product owner, 2026-10-09, of
    /// a wider gap: "this distance … looks a bit bad"). The pane's own 14pt
    /// header padding adds to this.
    static let headerLeadingClearance = leadingControlsLeading + leadingControlsWidth + 12

    /// The controls' left edge with no titlebar band (fullscreen): there are no
    /// traffic lights to stand off from, but the icon strip is narrower than
    /// the three controls, so hugging the window's edge left › straddling the
    /// strip and the card's rounded corner (product owner, 2026-10-25: "this
    /// looks bad in the top left"). They stand inside the card, a short step
    /// from its edge, as a pane's own header content does.
    static let fullscreenLeadingControlsLeading: CGFloat = StudioNavigationRail.compactRailWidth + 10

    /// The same clearance with no titlebar band (fullscreen), where the
    /// controls sit in flow at the left edge.
    static let fullscreenHeaderLeadingClearance = fullscreenLeadingControlsLeading + leadingControlsWidth + 12
}

/// Room that chrome drawn *over* a pane's top-right corner claims on the
/// window's chrome line. Nothing laid out inside a pane's header row can move
/// these controls, so every row on that line gets out of their way instead —
/// and it does so from this one value rather than each pane re-deriving the
/// arithmetic (and forgetting a control).
struct StudioChromeLineReservation: Equatable {
    /// The active pane's swap control and close target, at the pane's
    /// top-right corner while the center tab strip is hidden.
    var paneControls: CGFloat = 0

    var total: CGFloat { paneControls }
}

/// NSToolbar that tolerates unbalanced KVO removals.
///
/// On macOS 26, SwiftUI's `BarAppearanceBridge` can remove a toolbar
/// `displayMode` observation it never registered on this manually installed
/// toolbar when replacing the window's root SwiftUI content. That throws
/// `NSRangeException` inside
/// `NSHostingView.updateConstraints`, AppKit escalates it to
/// `+[NSApplication _crashOnException:]`, and the main thread never returns —
/// a permanent beachball until force quit (ui-stall sample + HIExceptions
/// fault). Track registrations per (observer, keyPath,
/// context) and silently drop removals that have no matching registration so
/// the framework's imbalance can't take down the window.
final class KVOTolerantToolbar: NSToolbar {
    private struct ObservationKey: Hashable {
        let observer: ObjectIdentifier
        let keyPath: String
        let context: UInt
    }

    /// Registration counts. Toolbar KVO traffic is main-thread only
    /// (AppKit/SwiftUI bridge), so no synchronization is needed.
    private var observationCounts: [ObservationKey: Int] = [:]

    private static let logger = Logger(subsystem: "com.foreverlm", category: "WindowChrome")

    override func addObserver(
        _ observer: NSObject,
        forKeyPath keyPath: String,
        options: NSKeyValueObservingOptions,
        context: UnsafeMutableRawPointer?
    ) {
        let key = ObservationKey(
            observer: ObjectIdentifier(observer),
            keyPath: keyPath,
            context: UInt(bitPattern: context)
        )
        observationCounts[key, default: 0] += 1
        super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
    }

    override func removeObserver(
        _ observer: NSObject,
        forKeyPath keyPath: String,
        context: UnsafeMutableRawPointer?
    ) {
        let key = ObservationKey(
            observer: ObjectIdentifier(observer),
            keyPath: keyPath,
            context: UInt(bitPattern: context)
        )
        guard let count = observationCounts[key], count > 0 else {
            Self.logger.error("Ignoring unbalanced KVO removal for \(keyPath, privacy: .public) (context variant)")
            return
        }
        observationCounts[key] = count - 1
        super.removeObserver(observer, forKeyPath: keyPath, context: context)
    }

    override func removeObserver(_ observer: NSObject, forKeyPath keyPath: String) {
        // The contextless variant matches any registration for this
        // observer/keyPath pair, mirroring KVO's own lookup order.
        let observerID = ObjectIdentifier(observer)
        guard let (key, count) = observationCounts.first(where: {
            $0.key.observer == observerID && $0.key.keyPath == keyPath && $0.value > 0
        }) else {
            Self.logger.error("Ignoring unbalanced KVO removal for \(keyPath, privacy: .public)")
            return
        }
        observationCounts[key] = count - 1
        super.removeObserver(observer, forKeyPath: keyPath)
    }
}

/// Gives the Studio window its spacious, Codex-style top bar.
///
/// A bare hidden-title-bar window has a ~32pt titlebar band, which leaves the
/// in-band chrome (sidebar toggle, reader title, source tabs) cramped against
/// the traffic lights. Handing the window an *empty* unified toolbar grows the
/// band to ~52pt and makes AppKit vertically center and indent the traffic
/// lights within it, so every header that centers itself in the band lands on
/// the lights' center line for free. The toolbar carries no items and the
/// title bar stays transparent, so nothing is drawn over the SwiftUI content
/// and clicks in the band still reach it.
///
/// If `StudioTopBar.extraBandHeight` is raised above zero, headers extend that
/// far below the band and this chrome shifts the traffic lights down to the
/// taller bar's center, re-applying from a frame-change observer whenever
/// AppKit re-centers them in its own band (every resize does) — idempotent,
/// and quiet once the frames settle.
struct StudioWindowChrome: NSViewRepresentable {
    /// The top safe-area inset SwiftUI last laid the window out against. The
    /// band only ever changes underneath SwiftUI (the toolbar arrives after the
    /// first layout, fullscreen takes it away again), so the chrome watches
    /// this for the moment the two stop agreeing. See `reconcileBand`.
    var measuredTopSafeAreaInset: CGFloat = 0

    func makeNSView(context: Context) -> StudioWindowChromeView {
        StudioWindowChromeView()
    }

    func updateNSView(_ nsView: StudioWindowChromeView, context: Context) {
        guard let window = nsView.window else { return }
        Self.installTopBar(in: window)
        nsView.reconcileBand(measuredBy: measuredTopSafeAreaInset)
    }

    @MainActor
    static func installTopBar(in window: NSWindow) {
        if window.toolbar == nil {
            let toolbar = KVOTolerantToolbar(identifier: "studio.topBar")
            // Icon-only is load-bearing, not cosmetic: a label-carrying toolbar
            // reserves a second row, which leaves the band 66pt tall but keeps
            // the traffic lights on the icon row at 26pt — anything centered in
            // the band would then sit below them. Icon-only gives a 52pt band
            // with the lights centered in it.
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}

/// Lets drag gestures win over window-dragging for interactive chrome that
/// sits in the titlebar band. AppKit decides whether a click-drag in the band
/// moves the window by asking the deepest hit NSView for
/// `mouseDownCanMoveWindow`; SwiftUI's hosting view answers true, so an
/// `.onDrag` there (source-tab reordering) loses the race and the whole
/// window moves instead. Mounted as a `.background`, this view becomes that
/// deepest hit view and answers false, while mouse events keep routing
/// through the hosting view so the SwiftUI clicks, drags, drops, and context
/// menus above it still work.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragBlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragBlockerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Keeps a window from being moved by the user while the pointer is on a
/// control in the titlebar band, and while a press on one lasts.
///
/// A titlebar drag is the window server's, not the app's: it decides at the
/// mouse-down, from the window's `isMovable` as it stands then, before AppKit
/// hands the press to any view (that is why a hung app's window still drags by
/// its titlebar). Setting `isMovable` false inside the tab's `mouseDown`, as
/// build 266 did, came too late: the server had already taken the press as a
/// window move, so dragging a tab to the other pane slid the whole window
/// (product owner, 2026-11-06: "the whole window, like the entire app window,
/// will move to the right because I'm like dragging in the top toolbar").
///
/// So the carve-out is set before the press: `BandHoverTracker` holds the
/// window still while the pointer is over a registered band control, and the
/// press holds it until the click or the drag session ends. The empty band
/// around the controls stays movable. Only windows this made unmovable are
/// given back, and only once nothing holds them.
@MainActor
enum WindowMoveLock {
    enum Hold: Hashable {
        /// The pointer is over a band control.
        case hover
        /// A press on a band control, until its click or drag session ends.
        case press
    }

    private static var holds: [ObjectIdentifier: Set<Hold>] = [:]
    /// Windows this made unmovable, to be given back; a window someone else
    /// made unmovable stays as it was.
    private static var madeUnmovable = Set<ObjectIdentifier>()

    static func lock(_ window: NSWindow, for hold: Hold = .press) {
        let id = ObjectIdentifier(window)
        let wasHeld = !(holds[id]?.isEmpty ?? true)
        holds[id, default: []].insert(hold)
        guard !wasHeld, window.isMovable else { return }
        madeUnmovable.insert(id)
        window.isMovable = false
    }

    static func unlock(_ window: NSWindow?, for hold: Hold = .press) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        guard holds[id]?.remove(hold) != nil else { return }
        if hold == .press {
            // The pointer has moved while the press lasted (a drag session sends
            // no mouse-moved events), so the hover hold is re-read from where it
            // is now rather than left as it was at the press.
            BandHoverTracker.refresh(window)
        }
        guard holds[id]?.isEmpty ?? true else { return }
        holds[id] = nil
        if madeUnmovable.remove(id) != nil {
            window.isMovable = true
        }
    }

    static func isHeld(_ window: NSWindow, for hold: Hold) -> Bool {
        holds[ObjectIdentifier(window)]?.contains(hold) ?? false
    }
}

/// A row hung in the titlebar band from the top of what it is laid over, on
/// the band's own chrome across that whole width. The band is the window's
/// chrome, as Codex's is, but the panes under it reach into it: a pane's
/// `.background(Color)` extends into the band (the top safe area) by default,
/// and a list or scroll view scrolls its rows up under it (both measured in a
/// stand-alone window with this titlebar). Backing every row that
/// hangs in the band covers both, so only the row shows there. Hit-testable,
/// as the opaque backing was: a press on it falls to the titlebar's window
/// drag, never to a row hidden underneath.
///
/// File-private on purpose: this is the one place that paints in the band, and
/// the only way another file hangs a row there is `studioBandOverlay`, so no
/// pane can paint its own backing across the band and show a different color
/// from the pane beside it (the chat's white title row next to the Review's
/// grey one).
///
/// `backsBelowBand: false` stops the backing at the pane's top edge instead
/// of `StudioTopBar.extraBandHeight` below it. A center pane's tab strip
/// takes it: the pane under the strip draws its own first row, so the extra
/// grey read as a thin bar above the Reader, its surface starting 6pt lower
/// than the sidebar's beside it (product owner, 2026-11-24: "why is there a
/// little thin gray bar above this paper?"). The row keeps the full band, so
/// the tabs stay on the traffic lights' line.
fileprivate struct StudioBandRow<Row: View>: View {
    let band: CGFloat
    var backsBelowBand = true
    @ViewBuilder let row: () -> Row

    var body: some View {
        ZStack(alignment: .top) {
            StudioInsetCardStyle.chrome
                .frame(height: backsBelowBand ? band : -StudioTopBar.hangOffset(band: band))
            row()
        }
        .offset(y: StudioTopBar.hangOffset(band: band))
    }
}

/// Hangs one row in the titlebar band from the top of the view it modifies,
/// on the band's chrome (`StudioBandRow`). Every pane that draws a row in the
/// band without `studioChromeLineHeader` — a transcript's title, the Reader's
/// toolbar, the sources' tab bar — goes through this, so the band's backing is
/// decided in this file and nowhere else. `active` is for a pane that hangs
/// its row only in some states; nothing is drawn while it is false or the
/// window has no band (full screen).
private struct StudioBandOverlay<Row: View>: ViewModifier {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    let active: Bool
    let row: Row

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if active, let band = titlebarBandHeight {
                StudioBandRow(band: band) { row }
            }
        }
    }
}

extension View {
    func studioBandOverlay<Row: View>(
        active: Bool = true,
        @ViewBuilder _ row: () -> Row
    ) -> some View {
        modifier(StudioBandOverlay(active: active, row: row()))
    }
}

struct StudioChromeLineHeader<Header: View>: ViewModifier {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @Environment(\.studioChromeLineReservation) private var chromeReservation
    @Environment(\.studioCenterTabStripVisible) private var tabStripVisible
    let isOpaque: Bool
    /// The row is the pane's name alone, which a visible tab already shows.
    var yieldsToTab = false
    let header: Header

    func body(content: Content) -> some View {
        let drawsRow = !(yieldsToTab && tabStripVisible)
        // Contained before the insets are added, so the clip is the strip
        // between the window's leading chrome and the reserved trailing
        // controls — never the chrome itself.
        let row = header
            .studioChromeLineRowContainment()
            .padding(.leading, headerLeadingInset)
            .padding(.trailing, chromeReservation.total)
            .frame(height: titlebarBandHeight ?? StudioPanelChrome.headerHeight)
        return VStack(spacing: 0) {
            if titlebarBandHeight == nil && drawsRow {
                backing(row)
            }
            content
        }
        .overlay(alignment: .top) {
            // In the band every row is backed by the band's chrome
            // (`StudioBandRow`), so the pane under it never shows there.
            if let band = titlebarBandHeight, drawsRow {
                StudioBandRow(band: band) { row }
            }
        }
    }

    /// The in-flow row of a window with no band (fullscreen), widened to the
    /// pane only when it is backed. A row that paints nothing keeps the width
    /// its own controls ask for, which is what every existing pane's header is
    /// laid out against.
    @ViewBuilder
    private func backing<Row: View>(_ row: Row) -> some View {
        if isOpaque {
            row
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            row
        }
    }
}

/// How wide a pane's tabs are so its whole strip fits the pane. A strip
/// wider than its pane was centred by its frame and spilled out on both
/// sides: the first pane's first tab slid back under ‹ › and the sidebar
/// toggle, and the last ones under the pane beside it (product owner,
/// 2026-11-11: "This is still a visual mistake. Look at this overlap").
/// Every tab is one width, as Codex's are (2026-11-26); a crowded strip
/// narrows them all alike, and what still does not fit runs off the trailing
/// edge, never the leading one.
enum StudioCenterTabStripFit {
    /// The narrowest a crowded strip makes a tab.
    static let minimumTabWidth: CGFloat = 72
    /// The space between two tabs.
    static let spacing: CGFloat = 2

    /// What the strip spends besides its tabs: its two edges, + and the split
    /// button, and the spacing around them.
    static func fixedWidth(leadingPadding: CGFloat) -> CGFloat {
        leadingPadding + StudioTopBar.centerTabStripHorizontalPadding
            + 2 * StudioPanelChrome.centerTabCloseButtonSize + 3 * spacing
    }

    /// The width at which `count` tabs, with the spacing after each, fit in
    /// `available`: `preferred` when they all fit at it, never under `minimum`.
    static func tabWidth(
        count: Int,
        available: CGFloat,
        preferred: CGFloat = StudioCenterTabButton.width,
        minimum: CGFloat = minimumTabWidth
    ) -> CGFloat {
        guard count > 0 else { return preferred }
        let share = floor(available / CGFloat(count) - spacing)
        return max(minimum, min(preferred, share))
    }
}

/// The center area's side-by-side panes. A pane with two tabs or more draws
/// them as a strip in the titlebar band, its own header dropping below it; a
/// pane with one tab shows it alone, its header in the band. A tab dragged
/// from a strip to the window's side opens there beside the rest.
struct StudioCenterTabGroupsView<TabContent: View>: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @Environment(\.studioPanelTrailingOverflow) private var outerTrailingOverflow

    let onSessionDropAtEdge: (ReviewSessionTransfer, Bool) -> Void
    /// The chat store of a chat place in a pane, whose chats the strip draws
    /// as tabs; nil for every other place.
    let chatStore: (StudioCenterTab, UUID) -> StudioAssistantSessionStore?
    @ViewBuilder let tabContent: (StudioCenterTab) -> TabContent

    init(
        onSessionDropAtEdge: @escaping (ReviewSessionTransfer, Bool) -> Void = { _, _ in },
        chatStore: @escaping (StudioCenterTab, UUID) -> StudioAssistantSessionStore? = { _, _ in nil },
        @ViewBuilder tabContent: @escaping (StudioCenterTab) -> TabContent
    ) {
        self.onSessionDropAtEdge = onSessionDropAtEdge
        self.chatStore = chatStore
        self.tabContent = tabContent
    }

    /// The chat a tab's Rename… is naming, and the name typed so far.
    @State private var renamingChatID: String?
    @State private var renameText = ""

    /// Divider positions between groups as fractions of the center width
    /// (N-1 for N groups). Device-local display state, like the outer panel
    /// fractions; reset to equal splits whenever the group count changes.
    @State private var groupFractions: [CGFloat] = []
    @State private var dragStartFractions: [CGFloat] = []
    @State private var draggingTab: StudioCenterTab?
    /// The pane the dragged tab left: with Pages in two panes the tab alone
    /// does not say which copy moves.
    @State private var draggingFromGroupID: UUID?
    @State private var dropTarget: StudioCenterTabDropTarget?
    /// The kept places (`StudioKeptPaneTabs`) each pane has shown, by pane:
    /// they stay mounted behind its other tabs.
    @State private var keptPaneTabs: [UUID: Set<StudioCenterTab>] = [:]
    /// The pane a sidebar destination is being dragged over, by slot.
    @State private var replaceTarget: Int?
    private let dragVisibility = StudioDragVisibility.shared

    private let dividerWidth = StudioCenterTabGroupSizing.dividerWidth
    private let edgeSplitZoneWidth: CGFloat = 22

    /// Whether the drag in flight carries content the pane under the pointer
    /// can take itself — a source, or a Doc or Site record — rather than a bare
    /// pane or a chat. Only those have a competing destination inside the pane.
    private var isDraggingSource: Bool {
        StudioCenterTabSplitPreviewSizing.dragCarriesPaneContent(
            draggedArticleCount: dragVisibility.draggedArticleIds.count,
            draggedArtifactID: dragVisibility.draggedArtifactID != nil,
            draggedSessionID: dragVisibility.draggedSessionID != nil,
            draggingTab: draggingTab != nil
        )
    }

    var body: some View {
        GeometryReader { geo in
            let groups = windowState.centerTabGroups.groups
            let fractions = validFractions(count: groups.count)
            let fullScreenID = windowState.fullScreenGroup?.id
            HStack(spacing: 0) {
                // Keyed on the group's own identity, not its slot. Reordering
                // the panes then moves each column's hosted views — the
                // reader's web view keeps its loaded page, scroll position and
                // find state, and the chat keeps every bubble's measured
                // height. Keyed by `\.offset` the slots stayed put while their
                // contents changed, so a swap rebuilt both panes from scratch.
                // `index` is still what the widths and dividers are addressed
                // by, so it stays in the element.
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    // Full screen draws its pane alone, across the whole
                    // center; the others leave and come back as they were.
                    // Filtered inside the same ForEach, so the full-screen
                    // pane keeps its identity and its reader its loaded page.
                    if let fullScreenID, group.id != fullScreenID {
                        EmptyView()
                    } else {
                        let width = fullScreenID == nil
                            ? groupWidth(at: index, fractions: fractions, count: groups.count, totalWidth: geo.size.width)
                            : geo.size.width
                        groupColumn(
                            group,
                            at: index,
                            isLeading: index == 0 || fullScreenID != nil,
                            width: width,
                            enclosingClip: StudioCenterTabGroupSizing.clippedTrailingWidth(
                                groupStart: fullScreenID == nil
                                    ? groupStart(at: index, fractions: fractions, count: groups.count, totalWidth: geo.size.width)
                                    : 0,
                                groupWidth: width,
                                totalWidth: geo.size.width,
                                enclosingOverflow: outerTrailingOverflow
                            )
                        )
                        if fullScreenID == nil, index < groups.count - 1 {
                            dividerHandle(at: index, groups: groups, totalWidth: geo.size.width)
                        }
                    }
                }
            }
            // The window goes full screen with its pane, and comes back out
            // with it when Full Screen made it so.
            .background(StudioPaneFullScreenWindowBridge(
                isFullScreen: fullScreenID != nil,
                onWindowLeftFullScreen: { windowState.fullScreenGroupID = nil }
            ))
            .overlay(alignment: .leading) {
                if fullScreenID == nil {
                    edgeSplitPreview(
                        leading: true,
                        groups: groups,
                        fractions: fractions,
                        totalWidth: geo.size.width
                    )
                }
            }
            .overlay(alignment: .trailing) {
                if fullScreenID == nil {
                    edgeSplitPreview(
                        leading: false,
                        groups: groups,
                        fractions: fractions,
                        totalWidth: geo.size.width
                    )
                }
            }
            .overlay(alignment: .leading) {
                if fullScreenID == nil {
                    edgeSplitZone(
                        leading: true,
                        groups: groups,
                        fractions: fractions,
                        totalWidth: geo.size.width
                    )
                }
            }
            .overlay(alignment: .trailing) {
                if fullScreenID == nil {
                    edgeSplitZone(
                        leading: false,
                        groups: groups,
                        fractions: fractions,
                        totalWidth: geo.size.width
                    )
                }
            }
            // Keep divider drag translation anchored to the stationary center
            // area. A divider's local coordinates move as its width updates,
            // feeding that movement back into the next drag event as jitter.
            .coordinateSpace(.named("centerTabGroups"))
            .onChange(of: groups.count) { _, count in
                groupFractions = Self.equalFractions(count: count)
            }
            .onAppear {
                if groupFractions.count != max(groups.count - 1, 0) {
                    groupFractions = Self.equalFractions(count: groups.count)
                }
            }
        }
        // A chat tab's double-click or Rename… renames its chat, as the
        // sidebar's Rename Chat does.
        .alert("Rename Chat", isPresented: Binding(
            get: { renamingChatID != nil },
            set: { if !$0 { renamingChatID = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingChatID = nil }
            Button("Rename") {
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingChatID, !title.isEmpty {
                    Task { await vm.renameReviewSession(id, title: title) }
                }
                renamingChatID = nil
            }
        }
    }

    // MARK: Group column

    /// - Parameters:
    ///   - isLeading: Whether the column stands at the center's leading edge,
    ///     under the traffic lights: the first pane, or the full-screen one.
    ///   - width: The group's column width in the groups layout.
    ///   - enclosingClip: How much of that column the outer Reader column clips
    ///     off its trailing edge (`StudioCenterTabGroupSizing.clippedTrailingWidth`).
    ///     Zero for every group that is fully on screen.
    private func groupColumn(
        _ group: StudioCenterTabGroups.Group,
        at index: Int,
        isLeading: Bool,
        width: CGFloat,
        enclosingClip: CGFloat
    ) -> some View {
        // The pane's chrome — its minimum width, the band it rises into, the
        // traffic-light clearance for the leftmost group, what overlays its
        // corner, where the close goes — is `StudioPaneHost`'s, shared with
        // the notebook workspace's slots. The tab strip rides in the titlebar
        // band, as Claude's title does, so the tabs are the top bar (product
        // owner, 2026-11-02: "tabs at the top of the screen, but when clicking
        // and dragging them DONT drag the whole ForeverLM console"). A press on
        // a tab or a drag of one must never move the window: the pointer on a
        // tab holds the window in place before the press, and the press for as
        // long as it lasts (`WindowMoveLock`), and only the strip's empty tail and the band
        // beside it still drag it. While a strip is drawn the band is cleared
        // so the pane renders its compact in-flow toolbar below it. Full
        // screen has no band: the strip is then the pane's first row.
        let showsStrip = group.showsTabStrip
        return StudioPaneHost(
            activeTab: group.activeTab,
            width: width,
            enclosingClip: enclosingClip,
            leadingReservation: isLeading ? headerLeadingInset : 0,
            bandPassesThrough: !showsStrip,
            swapDestinationCount: StudioPaneSwap.centerDestinations.count
        ) {
            VStack(spacing: 0) {
                if titlebarBandHeight == nil && showsStrip {
                    strip(for: group, at: index, isLeading: isLeading)
                        .frame(height: StudioPanelChrome.headerHeight)
                }
                // The tab in front, and behind it each kept place this pane
                // has shown (`StudioKeptPaneTabs`), keyed by tab so a switch
                // hides one and shows the other instead of rebuilding either.
                ZStack {
                    ForEach(mountedTabs(of: group), id: \.self) { tab in
                        let isShown = tab == group.activeTab
                        tabContent(tab)
                            .environment(\.studioPaneGroupID, group.id)
                            .environment(\.studioPaneTabIsShown, isShown)
                            .environment(\.studioPaneIsLeading, isLeading)
                            .modifier(StudioKeptPaneTabVisibility(isShown: isShown))
                    }
                }
                .onChange(of: group.activeTab, initial: true) { _, tab in
                    guard StudioKeptPaneTabs.places.contains(tab) else { return }
                    keptPaneTabs[group.id, default: []].insert(tab)
                }
                // A kept tab closed from the strip goes: it unmounts, and its
                // surface saves on the way out as any closed tab does.
                .onChange(of: group.openTabs) { _, open in
                    keptPaneTabs[group.id]?.formIntersection(open)
                }
            }
        } corner: { corner in
            StudioPaneSwapControl(
                corner: corner,
                destinations: StudioPaneSwap.centerDestinations,
                current: group.activeTab,
                identifierPrefix: "studio.centerPane.\(index)",
                onSelect: { destination in
                    vm.replaceCenterPane(
                        at: index,
                        with: destination.tab,
                        startsBlankChat: destination.startsBlankChat,
                        in: windowState
                    )
                }
            )
        } band: {
            if let band = titlebarBandHeight, showsStrip {
                StudioBandRow(band: band, backsBelowBand: false) {
                    strip(for: group, at: index, isLeading: isLeading)
                        .frame(height: band)
                }
            }
        }
        // A destination dragged from the sidebar onto this pane shows here,
        // in place of what the pane showed. The edge zones above sit over the
        // pane's outer gutters, so a drop there still opens beside.
        .overlay {
            StudioPaneReplaceDropTarget(
                onTargeted: { targeted in
                    if targeted {
                        replaceTarget = index
                    } else if replaceTarget == index {
                        replaceTarget = nil
                    }
                },
                onDrop: { replacePane(at: index, with: $0) }
            )
        }
        .overlay {
            StudioDropZoneOverlay(isActive: replaceTarget == index, cornerRadius: 10, inset: 6)
        }
        // The pane clicked in last is where a sidebar click opens what is not
        // open yet (`StudioCenterTabGroups.activating`).
        .background(StudioPaneFocusObserver { windowState.focusedGroupID = group.id })
    }

    /// What `group` mounts, in strip order: the tab in front, and each kept
    /// place it has shown in this run that is still in its strip. A kept place
    /// restored into the strip at launch waits until it is first shown.
    private func mountedTabs(of group: StudioCenterTabGroups.Group) -> [StudioCenterTab] {
        let kept = keptPaneTabs[group.id] ?? []
        return group.openTabs.filter { $0 == group.activeTab || kept.contains($0) }
    }

    private func replacePane(at index: Int, with destination: StudioPaneDropDestination) {
        replaceTarget = nil
        // A tab from another window's strip joins this pane's tabs, at the
        // end, rather than taking the pane over.
        if case .tab(let payload) = destination,
           let origin = StudioCenterTabWindowDrag.arriving(in: windowState, tab: payload.tab) {
            receiveFromAnotherWindow(origin, .strip(group: index, position: .max))
            return
        }
        vm.showDropped(destination, inPaneAt: index, in: windowState)
    }

    // MARK: Tabs from another window

    /// A tab dragged here from another window's strip (product owner,
    /// 2026-11-08: "if I have a chat on my right display I need to be able to
    /// drag it and then pop it over to the other window"): it opens where it
    /// was dropped and closes in the window it left. A chat moves as its own
    /// conversation, live; every other place through
    /// `StudioViewModel.moveCenterTab(_:fromGroup:of:arriving:in:)`.
    private func receiveFromAnotherWindow(
        _ origin: StudioCenterTabWindowDrag.Origin,
        _ arrival: StudioViewModel.CenterTabArrival
    ) {
        StudioCenterTabWindowDrag.endNow()
        StudioDragVisibility.shared.endNow()
        dropTarget = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            if let originStore = origin.chatStore {
                receiveChat(from: origin, store: originStore, arrival)
            } else {
                vm.moveCenterTab(origin.tab, fromGroup: origin.groupID, of: origin.window, arriving: arrival, in: windowState)
            }
        }
    }

    /// The chat of a chat tab from another window, in the pane it was dropped
    /// on: another chat tab there when the pane already has a chat, else this
    /// window's Chat when it is not open, else a side chat. Its manager comes
    /// with it (`handOverChat`), so a turn still answering carries on here;
    /// the chat that pane showed keeps a tab of its own. In the window it
    /// left, its tab closes, or with no other chat tab there its place does,
    /// as the × would.
    private func receiveChat(
        from origin: StudioCenterTabWindowDrag.Origin,
        store originStore: StudioAssistantSessionStore,
        _ arrival: StudioViewModel.CenterTabArrival
    ) {
        guard let landing = chatLanding(for: arrival),
              let store = chatStore(landing.place, landing.paneID),
              store !== originStore else { return }
        let (paneID, place) = (landing.paneID, landing.place)
        let sessionID = origin.chatSessionID
        let alreadyHere = sessionID.flatMap { id in store.shownChatTabs.first { $0.sessionID == id } }
        let manager = alreadyHere == nil ? sessionID.flatMap { originStore.handOverChat($0) } : nil

        if originStore.chatTabs.count > 1, let chatTabID = origin.chatTabID {
            originStore.closeChatTab(chatTabID)
        } else {
            vm.closeCenterTab(origin.tab, fromGroup: origin.groupID, in: origin.window)
        }
        // One chat is never drawn by two panels.
        if let sessionID { originStore.releaseChat(sessionID) }

        windowState.focusedGroupID = paneID
        vm.activateCenterTab(place, in: windowState)
        if let alreadyHere {
            if !store.chatTabs.isEmpty { store.selectChatTab(alreadyHere.id) }
            return
        }
        let showsAChat = store.activeSessionID != nil || store.isOpeningChat || !store.chatTabs.isEmpty
        if showsAChat { store.addChatTab() }
        if let manager {
            store.takeHandedOverChat(manager)
        } else if let sessionID {
            store.requestOpen(sessionID: sessionID)
            store.noteShownSession(sessionID)
        } else if showsAChat {
            // A chat not yet sent arrives as one.
            if place == .chat {
                vm.inWindow(windowState) { vm.requestNewChat() }
            } else {
                store.closeActiveChat()
            }
        }
    }

    /// The pane a chat from another window lands in and the chat place it
    /// shows there.
    private func chatLanding(for arrival: StudioViewModel.CenterTabArrival) -> (paneID: UUID, place: StudioCenterTab)? {
        let layout = windowState.centerTabGroups
        switch arrival {
        case .strip(let group, _):
            guard !layout.groups.isEmpty else { return nil }
            let pane = layout.groups[max(0, min(group, layout.groups.count - 1))]
            if let place = pane.openTabs.first(where: { chatStore($0, pane.id) != nil }) {
                return (paneID: pane.id, place: place)
            }
        case .edge(let leading):
            // No room for a pane of its own: the edge pane's strip takes it.
            if !layout.canCreateDraggedGroup, layout.arrivingPlace(for: .chat) != .chat {
                return chatLanding(for: .strip(group: leading ? 0 : layout.groups.count - 1, position: .max))
            }
        }
        let place = layout.arrivingPlace(for: .chat)
        guard let paneID = vm.receiveCenterTab(place, arriving: arrival, in: windowState) else { return nil }
        return (paneID: paneID, place: place)
    }

    // MARK: Tab strip

    private func strip(
        for group: StudioCenterTabGroups.Group,
        at groupIndex: Int,
        isLeading: Bool
    ) -> some View {
        let readerShowsVideo = vm.readerShowsVideo(in: windowState)
        let spaceTitle = vm.spaceTabTitle(in: windowState)
        // The leftmost pane's first tab starts after what the leading edge
        // holds: the traffic lights in the band, and in full screen ‹ › and
        // the sidebar toggle, which stand on this very row (the Chat tab would
        // otherwise sit on the toggle).
        let leadingPadding = isLeading
            ? max(StudioTopBar.centerTabStripHorizontalPadding, headerLeadingInset)
            : StudioTopBar.centerTabStripHorizontalPadding
        let tabCount = group.openTabs.reduce(0) { count, tab in
            count + (chatStore(tab, group.id)?.shownChatTabs.count ?? 1)
        }
        return GeometryReader { geo in
        let tabWidth = StudioCenterTabStripFit.tabWidth(
            count: tabCount,
            available: geo.size.width - StudioCenterTabStripFit.fixedWidth(leadingPadding: leadingPadding)
        )
        HStack(spacing: StudioCenterTabStripFit.spacing) {
            ForEach(Array(group.openTabs.enumerated()), id: \.element) { tabIndex, tab in
                if dropTarget == .tab(group: groupIndex, index: tabIndex) {
                    dropIndicatorCapsule
                }
                let title = tab.stripTitle(readerShowsVideo: readerShowsVideo, spaceTitle: spaceTitle)
                let systemImage = tab.stripSystemImage(readerShowsVideo: readerShowsVideo)
                if let store = chatStore(tab, group.id) {
                    // A chat place is a tab per chat it keeps (`ChatTab`),
                    // each named after its chat and renamed in place.
                    ForEach(store.shownChatTabs) { chatTab in
                        tabButton(
                            tab, in: group, at: groupIndex, tabIndex: tabIndex,
                            chat: (store, chatTab),
                            title: chatTabTitle(chatTab),
                            tabWidth: tabWidth,
                            systemImage: systemImage,
                            isActive: group.activeTab == tab && store.isActiveChatTab(chatTab),
                            action: {
                                windowState.focusedGroupID = group.id
                                vm.activateCenterTab(tab, in: windowState)
                                store.selectChatTab(chatTab.id)
                            },
                            // A close is never animated: the pane swaps at
                            // once, with no fade relaying out both surfaces.
                            onClose: {
                                if !store.closeChatTab(chatTab.id) {
                                    vm.closeCenterTab(tab, fromGroup: group.id, in: windowState)
                                }
                            },
                            onRename: chatTab.sessionID.map { sessionID -> () -> Void in
                                {
                                    renameText = vm.reviewSessionLinks.first { $0.id == sessionID }?.title ?? ""
                                    renamingChatID = sessionID
                                }
                            }
                        )
                    }
                } else {
                    tabButton(
                        tab, in: group, at: groupIndex, tabIndex: tabIndex,
                        title: title,
                        tabWidth: tabWidth,
                        systemImage: systemImage,
                        isActive: group.activeTab == tab,
                        action: {
                            // This pane's copy, when the place stands in several.
                            windowState.focusedGroupID = group.id
                            vm.activateCenterTab(tab, in: windowState)
                        },
                        onClose: {
                            vm.closeCenterTab(tab, fromGroup: group.id, in: windowState)
                        }
                    )
                }
            }
            if dropTarget == .stripEnd(group: groupIndex) {
                dropIndicatorCapsule
            }
            // + adds a tab: what the pane shows now stays one of its tabs
            // (`replaceCenterPane`), so the pane takes the new place in front.
            TitlebarBandButton(
                help: "New tab",
                accessibilityLabel: "New tab",
                accessibilityIdentifier: "studio.centerPane.\(groupIndex).newTab",
                washInset: StudioPaneSwap.washInset,
                cornerRadius: 6,
                action: {},
                menu: { [vm, windowState] in
                    StudioPaneSwapMenu(
                        destinations: StudioPaneSwap.newTabDestinations,
                        // + adds a tab: nothing is ticked, and with a chat
                        // already here Chat is another one (`addChatTab`).
                        current: nil,
                        title: { destination in
                            destination.tab == .chat && paneChatStore(in: group) != nil ? "New Chat" : nil
                        },
                        onSelect: { destination in
                            if destination.tab == .chat, let store = paneChatStore(in: group) {
                                addChatTab(to: store, in: group)
                                return
                            }
                            vm.replaceCenterPane(
                                at: groupIndex,
                                with: destination.tab,
                                startsBlankChat: destination.startsBlankChat,
                                in: windowState
                            )
                        }
                    )
                }
            ) {
                Image(systemName: "plus")
                    .zoomedSystemFont(size: 14, weight: .light)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: StudioPanelChrome.centerTabCloseButtonSize,
                        height: StudioPanelChrome.centerTabCloseButtonSize
                    )
            }
            // The strip's empty tail appends a dragged tab to this group.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: StudioCenterTabDragPayload.dropTypes, delegate: StudioCenterTabDropDelegate(
                    target: .stripEnd(group: groupIndex),
                    draggingTab: $draggingTab,
                    dropTarget: $dropTarget,
                    arriving: { [windowState] in StudioCenterTabWindowDrag.arriving(in: windowState) },
                    perform: { vm.moveCenterTab($0, fromGroup: draggingFromGroupID, toGroup: groupIndex, at: .max, in: windowState) },
                    receive: { receiveFromAnotherWindow($0, .strip(group: groupIndex, position: .max)) }
                ))

            // No pane × at the end: every tab carries its own, and a lone
            // tab's × dismisses the pane the way the pane × did (product
            // owner, 2026-11-07: "if each of those individual tabs will have a
            // small X mark, then we don't need that big X mark anymore").
            // In its place, the split a terminal has: a new pane beside this
            // one (product owner, 2026-11-07: "have like two things side by
            // side whenever we want ... to click like a plus").
            splitButton(for: group, at: groupIndex)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, StudioTopBar.centerTabStripHorizontalPadding)
        // Leading: a strip that still overflows runs off the trailing edge,
        // never back under the controls at the leading one.
        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    /// One tab of a pane's strip: the chip, its drag, its menu and its drop.
    private func tabButton(
        _ tab: StudioCenterTab,
        in group: StudioCenterTabGroups.Group,
        at groupIndex: Int,
        tabIndex: Int,
        chat: (store: StudioAssistantSessionStore, tab: StudioAssistantSessionStore.ChatTab)? = nil,
        title: String,
        tabWidth: CGFloat,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onRename: (() -> Void)? = nil
    ) -> some View {
        let isAlone = group.openTabs == [tab]
        let atCapacity = !windowState.centerTabGroups.canCreateDraggedGroup
        return StudioCenterTabButton(
            title: title,
            systemImage: systemImage,
            isActive: isActive,
            action: action,
            payload: StudioCenterTabDragPayload.string(for: tab),
            onDragBegan: {
                draggingTab = tab
                draggingFromGroupID = group.id
                dropTarget = nil
                // Another window may take it (`StudioCenterTabWindowDrag`).
                StudioCenterTabWindowDrag.begin(.init(
                    window: windowState,
                    groupID: group.id,
                    tab: tab,
                    chatStore: chat?.store,
                    chatTabID: chat?.tab.id,
                    chatSessionID: chat?.tab.sessionID
                ))
            },
            onDragEnded: {
                draggingTab = nil
                draggingFromGroupID = nil
                dropTarget = nil
                StudioCenterTabWindowDrag.endSoon()
            },
            splitLeftEnabled: isAlone ? groupIndex > 0 : !atCapacity,
            splitRightEnabled: isAlone ? groupIndex < windowState.centerTabGroups.groups.count - 1 : !atCapacity,
            onSplitLeft: { vm.splitCenterTab(tab, fromGroup: group.id, towardRight: false, in: windowState) },
            onSplitRight: { vm.splitCenterTab(tab, fromGroup: group.id, towardRight: true, in: windowState) },
            onClose: onClose,
            onRename: onRename,
            tabWidth: tabWidth
        )
        .onDrop(of: StudioCenterTabDragPayload.dropTypes, delegate: StudioCenterTabDropDelegate(
            target: .tab(group: groupIndex, index: tabIndex),
            draggingTab: $draggingTab,
            dropTarget: $dropTarget,
            arriving: { [windowState] in StudioCenterTabWindowDrag.arriving(in: windowState) },
            perform: { vm.moveCenterTab($0, fromGroup: draggingFromGroupID, toGroup: groupIndex, at: tabIndex, in: windowState) },
            receive: { receiveFromAnotherWindow($0, .strip(group: groupIndex, position: tabIndex)) }
        ))
    }

    /// A chat tab's name: its chat's title, "New Chat" before the first
    /// message, and "Chat" for one whose title has not come yet.
    private func chatTabTitle(_ chatTab: StudioAssistantSessionStore.ChatTab) -> String {
        guard let sessionID = chatTab.sessionID else { return "New Chat" }
        let title = vm.reviewSessionLinks.first { $0.id == sessionID }?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Chat" : title
    }

    /// The pane's chat store when `tab` is a chat place in it, for + to add
    /// a chat tab to.
    private func paneChatStore(in group: StudioCenterTabGroups.Group) -> StudioAssistantSessionStore? {
        group.openTabs.lazy.compactMap { chatStore($0, group.id) }.first
    }

    /// + › Chat in a pane that already has a chat: another chat tab there,
    /// blank, the chat it showed kept in its own tab (product owner,
    /// 2026-11-08: "i need to be able to add more chats").
    private func addChatTab(to store: StudioAssistantSessionStore, in group: StudioCenterTabGroups.Group) {
        guard let place = group.openTabs.first(where: { chatStore($0, group.id) != nil }) else { return }
        windowState.focusedGroupID = group.id
        vm.activateCenterTab(place, in: windowState)
        store.addChatTab()
        if place == .chat {
            // The window's chat starts a new chat the ordinary way.
            vm.inWindow(windowState) { vm.requestNewChat() }
        } else {
            store.closeActiveChat()
        }
    }

    /// The split button: a menu of places, the pick opening in a new pane to
    /// the right (`StudioViewModel.splitPane`). A place that can stand in
    /// several panes opens as a fresh copy, and Chat as a new side chat; any
    /// other moves out of the pane that has it. What this pane shows is offered only when it can be
    /// copied, since moving it would only move this pane. Disabled at the
    /// pane limit.
    private func splitButton(for group: StudioCenterTabGroups.Group, at groupIndex: Int) -> some View {
        // The Reader too, which the + does not offer: beside a Reader it is
        // a second one.
        var places = StudioPaneSwap.newTabDestinations
        places.insert(.init(tab: .reader), at: min(1, places.count))
        let destinations = places.filter {
            $0.tab != group.activeTab || $0.tab.splitCopy != nil
        }
        return TitlebarBandButton(
            help: "Split Right (⌘\\)",
            accessibilityLabel: "Split Right",
            accessibilityIdentifier: "studio.centerPane.\(groupIndex).split",
            washInset: StudioPaneSwap.washInset,
            cornerRadius: 6,
            isEnabled: windowState.centerTabGroups.canCreateDraggedGroup,
            action: {},
            menu: { [vm, windowState] in
                StudioPaneSwapMenu(
                    destinations: destinations,
                    current: group.activeTab,
                    onSelect: { destination in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            vm.splitPane(at: groupIndex, showing: destination.tab, in: windowState)
                        }
                        if destination.startsBlankChat { vm.inWindow(windowState) { vm.requestNewChat() } }
                    }
                )
            }
        ) {
            Image(systemName: "square.split.2x1")
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(
                    width: StudioPanelChrome.centerTabCloseButtonSize,
                    height: StudioPanelChrome.centerTabCloseButtonSize
                )
        }
    }

    private var dropIndicatorCapsule: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: StudioCenterTabButton.height - 4)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 3, x: 0, y: 0)
    }

    // MARK: Edge split zones

    /// An invisible destination at the far edge of the center area that turns a
    /// dragged tab into a new group there, VS Code style. During a tab drag its
    /// width matches the split preview, so every point inside the blue bounds is
    /// an actual drop target instead of only the outermost gutter. Its AppKit
    /// destination is
    /// registered before the drag begins; conditionally enabling a SwiftUI
    /// `.onDrop` target after `mouseDragged` is too late for the in-flight
    /// AppKit session, which made the visible trailing bar reject the drop.
    /// The destination's `hitTest` returns nil so this always-registered region
    /// never steals ordinary clicks or scrolling from the pane underneath. The
    /// SwiftUI shape that sizes it must stay out of hit testing too: with a
    /// `contentShape` it took every click in the pane's outer 22 pt, which is
    /// where the pane's overlay scroll bar draws its knob, so the knob could
    /// not be dragged. Dragging destinations are found from registered view
    /// bounds, not from hit testing, so the drop still lands.
    private func edgeSplitZone(
        leading: Bool,
        groups: [StudioCenterTabGroups.Group],
        fractions: [CGFloat],
        totalWidth: CGFloat
    ) -> some View {
        let previewWidth = edgeSplitPreviewWidth(
            leading: leading,
            groups: groups,
            fractions: fractions,
            totalWidth: totalWidth
        )
        return Rectangle()
            .fill(Color.clear)
            .frame(width: max(edgeSplitZoneWidth, previewWidth ?? 0))
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            .overlay {
                StudioCenterTabEdgeDropTarget(
                    onTargeted: { targeted in
                        let target = StudioCenterTabDropTarget.edge(leading: leading)
                        if targeted {
                            dropTarget = target
                        } else if dropTarget == target {
                            dropTarget = nil
                        }
                    },
                    onDrop: { payload in
                        // A tab from another window's strip opens here with
                        // what it showed, and leaves that window.
                        if let origin = StudioCenterTabWindowDrag.arriving(in: windowState, tab: payload.tab) {
                            receiveFromAnotherWindow(origin, .edge(leading: leading))
                            return
                        }
                        // A Docs-list row carries its doc beside the pane. Read
                        // it before the drag state is cleared below.
                        let draggedArtifactID = StudioDragVisibility.shared.draggedArtifactID
                        StudioDragVisibility.shared.endNow()
                        // The source window can remain key throughout a
                        // cross-display drag. Route by the destination view's
                        // scene state, not by the key-window registry.
                        vm.placeCenterTabAtEdge(
                            payload.tab,
                            fromGroup: draggingFromGroupID,
                            leading: leading,
                            in: windowState
                        )
                        // Dragged from a Docs row: the pane that just opened
                        // shows that doc. The row does not select itself as
                        // the drag begins — doing so would swap the open doc out
                        // from under a drop on its own page — so the edge
                        // split names the doc here instead.
                        if let draggedArtifactID {
                            switch payload.tab {
                            case .notepad:
                                vm.artifactRevealRequest = ArtifactRevealRequest(artifactID: draggedArtifactID, section: .docs, windowID: windowState.id)
                            case .sites:
                                vm.artifactRevealRequest = ArtifactRevealRequest(artifactID: draggedArtifactID, section: .sites, windowID: windowState.id)
                            default:
                                break
                            }
                        }
                        // Dragged from the rail's "New chat" row: the pane it
                        // just opened should hold a fresh conversation, not
                        // whichever one happened to be loaded. Scoped to this
                        // window for the same reason as the placement above:
                        // the request is stamped with the window in scope, and
                        // the key window is still the one the drag left.
                        if payload.startsBlankChat {
                            vm.inWindow(windowState) { vm.requestNewChat() }
                        }
                    },
                    onSessionDrop: { transfer in
                        StudioDragVisibility.shared.endNow()
                        onSessionDropAtEdge(transfer, leading)
                    },
                    onSourceDrop: { sourceID in
                        StudioDragVisibility.shared.endNow()
                        // A source dropped at a workspace edge means "read it
                        // here": reveal Reader at that edge and bind the source
                        // to this window, leaving the origin window untouched.
                        vm.placeCenterTabAtEdge(
                            .reader,
                            leading: leading,
                            in: windowState
                        )
                        Task {
                            await vm.selectArticle(sourceID, in: windowState)
                        }
                    }
                )
            }
    }

    @ViewBuilder
    private func edgeSplitPreview(
        leading: Bool,
        groups: [StudioCenterTabGroups.Group],
        fractions: [CGFloat],
        totalWidth: CGFloat
    ) -> some View {
        if shouldShowEdgeSplitPreview(leading: leading),
           let width = edgeSplitPreviewWidth(
               leading: leading,
               groups: groups,
               fractions: fractions,
               totalWidth: totalWidth
           ) {
            let targeted = dropTarget == .edge(leading: leading)
            Rectangle()
                .fill(Color.accentColor.opacity(targeted ? 0.14 : 0.07))
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            Color.accentColor.opacity(targeted ? 0.9 : 0.55),
                            lineWidth: 2
                        )
                }
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func shouldShowEdgeSplitPreview(leading: Bool) -> Bool {
        dropTarget == .edge(leading: leading)
            || (!leading && draggingTab != nil)
            || dragVisibility.draggedSessionID != nil
            || !dragVisibility.draggedArticleIds.isEmpty
            || dragVisibility.draggedCenterTab != nil
    }

    /// A grouped tab creates one equal-width pane. A tab that already owns a
    /// pane only reorders that pane, so preview the existing destination slot
    /// at the requested edge instead of implying another pane will be created.
    private func edgeSplitPreviewWidth(
        leading: Bool,
        groups: [StudioCenterTabGroups.Group],
        fractions: [CGFloat],
        totalWidth: CGFloat
    ) -> CGFloat? {
        if dragVisibility.draggedSessionID != nil
            || !dragVisibility.draggedArticleIds.isEmpty
            || dragVisibility.draggedArtifactID != nil {
            // The zone and the preview read the same width, so whatever is
            // highlighted is exactly what accepts the drop. A source keeps
            // that to a gutter and leaves the pane its own center. So does a
            // Docs or Sites row: its drag also carries its own pane, and read
            // as a pane drag below it sized the zone to the pane it would
            // move, which with Sites already open beside Chat was the whole
            // chat pane — a site dropped on the chat swapped the two panes
            // instead of joining the conversation.
            let cap = isDraggingSource
                ? StudioCenterTabSplitPreviewSizing.sourceEdgeZoneWidth(totalWidth: totalWidth)
                : .infinity
            if StudioCenterTabGroups(groups: groups).canCreateDraggedGroup {
                let width = StudioCenterTabSplitPreviewSizing.newPaneWidth(
                    totalWidth: totalWidth,
                    currentGroupCount: groups.count,
                    dividerWidth: dividerWidth,
                    maximumGroupCount: StudioCenterTabGroups.draggedGroupCount
                )
                return width > 0 ? min(width, cap) : nil
            }
            let destinationIndex = leading ? 0 : groups.count - 1
            return min(
                groupWidth(
                    at: destinationIndex,
                    fractions: fractions,
                    count: groups.count,
                    totalWidth: totalWidth
                ),
                cap
            )
        }

        // A tab from another window's strip comes in as this window's place
        // (`arrivingPlace`); a copy this window does not hold yet opens a pane
        // of its own, as a split would.
        let arrivingTab = draggingTab == nil
            ? StudioCenterTabWindowDrag.arriving(in: windowState)
                .map { StudioCenterTabGroups(groups: groups).arrivingPlace(for: $0.tab) }
            : nil
        guard let tab = draggingTab ?? arrivingTab ?? dragVisibility.draggedCenterTab else { return nil }

        // A destination dragged from the sidebar is taken by the pane under
        // the pointer, so the edge zones keep to a gutter and leave each pane
        // its middle, as they do for a source. So is a tab from another
        // window, which joins the pane it is dropped on.
        let cap = draggingTab == nil && (dragVisibility.isPaneDrag || arrivingTab != nil)
            ? StudioCenterTabSplitPreviewSizing.sourceEdgeZoneWidth(totalWidth: totalWidth)
            : .infinity

        guard let sourceIndex = groups.firstIndex(where: { $0.tabs.contains(tab) }),
              arrivingTab == nil || !tab.canStandInSeveralPanes else {
            guard arrivingTab != nil else { return nil }
            if StudioCenterTabGroups(groups: groups).canCreateDraggedGroup {
                let width = StudioCenterTabSplitPreviewSizing.newPaneWidth(
                    totalWidth: totalWidth,
                    currentGroupCount: groups.count,
                    dividerWidth: dividerWidth,
                    maximumGroupCount: StudioCenterTabGroups.draggedGroupCount
                )
                return width > 0 ? min(width, cap) : nil
            }
            let destinationIndex = leading ? 0 : groups.count - 1
            return min(groupWidth(at: destinationIndex, fractions: fractions, count: groups.count, totalWidth: totalWidth), cap)
        }

        // The same three outcomes as `StudioViewModel.placeCenterTabAtEdge`:
        // a pane of the tab's own moves to the edge, a tab sharing its pane
        // (or parked) opens a new pane there, and at the pane limit it joins
        // the edge pane.
        let isPaneOfItsOwn = groups[sourceIndex].openTabs == [tab]
        let movesItsPane = isPaneOfItsOwn && (groups.count > 1 || groups[sourceIndex].tabs == [tab])
        if !movesItsPane, StudioCenterTabGroups(groups: groups).canCreateDraggedGroup {
            let width = StudioCenterTabSplitPreviewSizing.newPaneWidth(
                totalWidth: totalWidth,
                currentGroupCount: groups.count,
                dividerWidth: dividerWidth,
                maximumGroupCount: StudioCenterTabGroups.draggedGroupCount
            )
            return width > 0 ? min(width, cap) : nil
        }

        let destinationIndex = leading ? 0 : groups.count - 1
        guard sourceIndex != destinationIndex else { return nil }
        return min(
            groupWidth(
                at: destinationIndex,
                fractions: fractions,
                count: groups.count,
                totalWidth: totalWidth
            ),
            cap
        )
    }

    // MARK: Widths and dividers

    private static func equalFractions(count: Int) -> [CGFloat] {
        guard count > 1 else { return [] }
        return (1..<count).map { CGFloat($0) / CGFloat(count) }
    }

    private func validFractions(count: Int) -> [CGFloat] {
        groupFractions.count == max(count - 1, 0) ? groupFractions : Self.equalFractions(count: count)
    }

    private func groupWidth(at index: Int, fractions: [CGFloat], count: Int, totalWidth: CGFloat) -> CGFloat {
        guard count > 1 else { return totalWidth }
        let usable = totalWidth - CGFloat(count - 1) * dividerWidth
        let left = index == 0 ? 0 : fractions[index - 1]
        let right = index == count - 1 ? 1 : fractions[index]
        return max(0, (right - left) * usable)
    }

    /// Leading edge of a group's column in the groups layout: the columns and
    /// dividers before it.
    private func groupStart(at index: Int, fractions: [CGFloat], count: Int, totalWidth: CGFloat) -> CGFloat {
        guard index > 0, count > 1 else { return 0 }
        let usable = totalWidth - CGFloat(count - 1) * dividerWidth
        return max(0, fractions[index - 1] * usable) + CGFloat(index) * dividerWidth
    }

    private func dividerHandle(
        at index: Int,
        groups: [StudioCenterTabGroups.Group],
        totalWidth: CGFloat
    ) -> some View {
        let count = groups.count
        return Rectangle()
            .fill(Color.clear)
            .frame(width: dividerWidth)
            // The visible line, with its short stroke in the titlebar band
            // between the groups' chrome lines.
            .overlay(StudioColumnHairline())
            // No grab slop into the neighbouring panes: a pane's overlay
            // scroll bar knob sits in exactly that strip. See the outer
            // panel divider for the book that showed it.
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("centerTabGroups"))
                    .onChanged { value in
                        if dragStartFractions.isEmpty {
                            dragStartFractions = validFractions(count: count)
                        }
                        let usable = totalWidth - CGFloat(count - 1) * dividerWidth
                        guard usable > 0, dragStartFractions.count == count - 1 else { return }
                        var fractions = validFractions(count: count)
                        let hardLower: CGFloat = index == 0 ? 0 : fractions[index - 1]
                        let hardUpper: CGFloat = index == count - 2 ? 1 : fractions[index + 1]
                        let raw = dragStartFractions[index] + value.translation.width / usable
                        let leadingMinimum = Self.minimumWidth(for: groups[index])
                        let trailingMinimum = Self.minimumWidth(for: groups[index + 1])
                        fractions[index] = StudioPaneDividerConstraint.clamp(
                            raw,
                            hardLower: hardLower,
                            hardUpper: hardUpper,
                            leadingMinimumWidth: leadingMinimum,
                            trailingMinimumWidth: trailingMinimum,
                            usableWidth: usable
                        )
                        groupFractions = fractions
                    }
                    .onEnded { _ in
                        dragStartFractions = []
                    }
            )
            // Keep the button above the divider's drag surface. Applying the
            // drag gesture after this overlay makes SwiftUI claim the click
            // before the button can turn it into a swap.
            .modifier(StudioPaneSwapAffordance(
                titlebarBandHeight: titlebarBandHeight,
                accessibilityIdentifier: "studio.centerPanes.swap",
                action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.swapCenterGroups(
                            adjacentToDividerAt: index,
                            in: windowState
                        )
                    }
                }
            ))
            // The swap button is wider than the divider so it can straddle the
            // hairline. Keep that overflow above both neighboring columns while
            // their contents animate into their new order; otherwise the column
            // rendered after the divider covers the button's trailing half.
            .zIndex(1)
    }

    private static func minimumWidth(for group: StudioCenterTabGroups.Group) -> CGFloat {
        [.chat, .secondaryChat].contains(group.activeTab)
            ? StudioCenterTabGroupSizing.minimumChatContentWidth
            : StudioCenterTabGroupSizing.minimumContentWidth
    }
}

// MARK: - Full screen

/// Takes the window into macOS full screen when a pane goes full screen
/// (`StudioWindowState.fullScreenGroupID`), and out again when the pane comes
/// back — only when it was Full Screen that took it in: a window the learner
/// had in full screen already stays there. The window leaving full screen by
/// itself (the green button, ⌃⌘F) brings the panes back too, since full
/// screen without the room is not what was asked for.
struct StudioPaneFullScreenWindowBridge: NSViewRepresentable {
    let isFullScreen: Bool
    let onWindowLeftFullScreen: () -> Void

    func makeNSView(context: Context) -> BridgeView {
        BridgeView()
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onWindowLeftFullScreen = onWindowLeftFullScreen
        view.setPaneFullScreen(isFullScreen)
    }

    final class BridgeView: NSView {
        var onWindowLeftFullScreen: () -> Void = {}
        private var paneIsFullScreen = false
        /// Whether this pane's Full Screen is what took the window in.
        private var tookWindowIn = false
        private var exitObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let exitObserver { NotificationCenter.default.removeObserver(exitObserver) }
            exitObserver = nil
            guard let window else { return }
            exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tookWindowIn = false
                    if self.paneIsFullScreen { self.onWindowLeftFullScreen() }
                }
            }
        }

        deinit {
            if let exitObserver { NotificationCenter.default.removeObserver(exitObserver) }
        }

        func setPaneFullScreen(_ fullScreen: Bool) {
            guard fullScreen != paneIsFullScreen else { return }
            paneIsFullScreen = fullScreen
            guard let window else { return }
            let windowIsFullScreen = window.styleMask.contains(.fullScreen)
            if fullScreen, !windowIsFullScreen {
                tookWindowIn = true
                window.toggleFullScreen(nil)
            } else if !fullScreen, tookWindowIn {
                tookWindowIn = false
                if windowIsFullScreen { window.toggleFullScreen(nil) }
            }
        }
    }
}
