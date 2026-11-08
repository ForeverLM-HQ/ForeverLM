import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
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

struct FinderFileDropTarget: NSViewRepresentable {
    let onTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FinderFileDropView {
        let view = FinderFileDropView()
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: FinderFileDropView, context: Context) {
        nsView.onTargeted = onTargeted
        nsView.onDrop = onDrop
    }
}

final class FinderFileDropView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    private let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            filenamesPasteboardType,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("public.url"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.tiff")
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            onTargeted?(false)
            return false
        }
        onDrop?(urls)
        onTargeted?(false)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }

        if let strings = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] {
            let urls = strings
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .filter { $0.isFileURL }
            if !urls.isEmpty { return urls }
        }

        for type in [NSPasteboard.PasteboardType.fileURL, .URL, NSPasteboard.PasteboardType("public.file-url"), NSPasteboard.PasteboardType("public.url")] {
            if let value = pasteboard.string(forType: type),
               let url = Self.fileURL(fromPasteboardString: value) {
                return [url]
            }
        }

        return []
    }

    private static func fileURL(fromPasteboardString value: String) -> URL? {
        let clean = value
            .replacingOccurrences(of: "\0", with: "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !clean.isEmpty else { return nil }
        if let url = URL(string: clean), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: (clean as NSString).expandingTildeInPath)
    }
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
    static let panelToggleBarHeight: CGFloat = 34
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

enum StudioBottomPanelSizing {
    static let defaultHeight: CGFloat = 168
    static let minHeight: CGFloat = 92
    static let maxHeight: CGFloat = 300
    static let dragHandleHeight: CGFloat = 30
    static let dividerHeight: CGFloat = 1
    static let collapsedHeight: CGFloat = 42
    static let floatingCornerRadius: CGFloat = 8

    static func contentHeight(for panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - dragHandleHeight - dividerHeight)
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
    /// Kept at zero after two failed experiments: shrinking the band itself
    /// (bare titlebar, 46pt) left the sources tab row blank on macOS 26, and
    /// extending the bar to 60pt (+8, 2026-07-23) shifted the lights off the
    /// sidebar toggle's line and read as dead air around them. The 52pt band
    /// with AppKit's own light centering is the known-good configuration.
    static let extraBandHeight: CGFloat = 0
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
/// fault, 2026-07-16 17:10). Track registrations per (observer, keyPath,
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

/// Watches the pointer over a window that has controls in its titlebar band and
/// holds the window still (`WindowMoveLock`, `.hover`) while the pointer is on
/// one of them, so a press there reaches the control instead of moving the
/// window. One per window, installed when the first band control registers.
///
/// It reads mouse-moved events from its own always-active tracking area over the
/// whole window, so it works in a window that is not key and in an app that is
/// not frontmost, the first press included.
@MainActor
final class BandHoverTracker: NSResponder {
    private static let trackers = NSMapTable<NSWindow, BandHoverTracker>.weakToStrongObjects()

    private weak var window: NSWindow?
    private weak var trackedView: NSView?
    private var trackingArea: NSTrackingArea?

    static func install(on window: NSWindow) {
        if let tracker = trackers.object(forKey: window) {
            tracker.attachIfNeeded()
            return
        }
        let tracker = BandHoverTracker(window: window)
        trackers.setObject(tracker, forKey: window)
        tracker.attachIfNeeded()
    }

    /// Re-reads whether the pointer is over a band control right now.
    static func refresh(_ window: NSWindow) {
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        update(window, at: point)
    }

    static func update(_ window: NSWindow, at pointInWindow: NSPoint) {
        if TitlebarBandHitSurfaceView.registeredSurface(at: pointInWindow, in: window) != nil {
            WindowMoveLock.lock(window, for: .hover)
        } else if WindowMoveLock.isHeld(window, for: .hover) {
            WindowMoveLock.unlock(window, for: .hover)
        }
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The tracking area sits on the window's frame view, which outlives any
    /// content view SwiftUI swaps in and covers the titlebar band too.
    private func attachIfNeeded() {
        guard let window, let host = window.contentView?.superview ?? window.contentView else { return }
        if trackedView === host, trackingArea != nil { return }
        if let trackingArea, let trackedView {
            trackedView.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        host.addTrackingArea(area)
        trackedView = host
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        Self.update(window, at: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let window else { return }
        WindowMoveLock.unlock(window, for: .hover)
    }
}

/// What a left press on a tab in the titlebar band came to.
enum TitlebarBandTabPress {
    case click
    /// The pointer crossed the drag threshold; the event that crossed it.
    case drag(NSEvent)
    case cancelled
}

/// Owns a press on a tab in the titlebar band from down to up.
///
/// AppKit hands a press in the band to the view under it and then, unless that
/// view consumes the drags that follow, turns them into a window move
/// (`TitlebarBandHitSurfaceView`). A tab that only noted the press and waited
/// for `mouseDragged` never got one: dragging a tab to the side to view it
/// beside the rest moved the whole window instead (product owner, 2026-10-22:
/// "they overlap with the full window tab bar at the top which will move the
/// entire window"). This loop takes the drags itself; a release is a click, a
/// move past `threshold` is the tab's drag, started from that event.
@MainActor
func trackTitlebarBandTabPress(
    _ mouseDown: NSEvent,
    in window: NSWindow,
    threshold: CGFloat = 4
) -> TitlebarBandTabPress {
    let start = mouseDown.locationInWindow
    var result = TitlebarBandTabPress.cancelled
    window.trackEvents(
        matching: [.leftMouseDragged, .leftMouseUp],
        timeout: NSEvent.foreverDuration,
        mode: .eventTracking
    ) { tracked, stop in
        guard let tracked else {
            stop.pointee = true
            return
        }
        switch tracked.type {
        case .leftMouseDragged:
            let point = tracked.locationInWindow
            if hypot(point.x - start.x, point.y - start.y) > threshold {
                result = .drag(tracked)
                stop.pointee = true
            }
        case .leftMouseUp:
            result = .click
            stop.pointee = true
        default:
            break
        }
    }
    return result
}

private let tabPressLogger = Logger(subsystem: "com.foreverlm", category: "TabPress")

private func tabPressOrigin(_ window: NSWindow?) -> String {
    guard let frame = window?.frame else { return "no window" }
    return "window at \(Int(frame.origin.x)),\(Int(frame.origin.y))"
}

/// Marks a registered band view whose control-clicks are not its own: they pass
/// on to the SwiftUI view underneath, whose `.contextMenu` they open.
protocol TitlebarBandControlClickPassthrough: NSView {}

/// The one mouse surface for a control that lives in the titlebar band.
///
/// A press on a band control used to slide the whole window: measured on the
/// shipped build 2026-08-31, pressing a pane close and moving the pointer 60pt
/// moved the window 54pt, and the click was lost whenever the pointer left the
/// control before the release. `mouseDownCanMoveWindow` does not prevent it —
/// AppKit delivers the mouse-down to the view either way and only *then*, if
/// nothing has consumed the drags that follow, converts them into a titlebar
/// window-move. Verified in both directions on a running build: with that
/// property alone the window still moved; with the tracking loop below it does
/// not, and the control acts.
///
/// So this view owns the press from down to up itself. Nothing interactive may
/// sit above it, or AppKit hands the sequence to that view instead: SwiftUI
/// draws the label and the wash and owns the accessibility element, and this
/// reports hover back for the wash. Use `TitlebarBandButton` rather than
/// mounting it directly. Sizing matters too — the previous native target took
/// its intrinsic size rather than the wash's, leaving a dead ring inside the
/// grey the pointer lights up.
final class TitlebarBandHitSurfaceView: NSView, NSDraggingSource {
    private static let registeredSurfaces = NSHashTable<NSView>.weakObjects()
    private static var mouseDownMonitor: Any?
    var action: () -> Void = {}
    /// When set, a press opens this menu instead of firing `action`. It opens on
    /// mouse-down, the way a native pop-up button does, and the menu's own
    /// tracking then owns the mouse until it closes — so the drags that follow
    /// can never be reinterpreted as a titlebar window-move either.
    var menuProvider: (() -> NSMenu)?
    var onHoverChange: (Bool) -> Void = { _ in }
    var onPressedChange: (Bool) -> Void = { _ in }
    /// When set, a press that moves past `dragThreshold` starts a drag of this
    /// pane destination instead of cancelling, so a band control can be both a
    /// button and a drag source (a pane's swap icons).
    var dragDestination: StudioCenterTabDragPayload.Payload?
    private static let dragThreshold: CGFloat = 4
    private var pendingDragEvent: NSEvent?

    private var hoverTrackingArea: NSTrackingArea?
    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            onPressedChange(isPressed)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Band controls behave like toolbar buttons: they act on the same click
    /// that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.unregisterFromBandRouter(self)
            isPressed = false
            onHoverChange(false)
        } else {
            Self.registerWithBandRouter(self)
        }
    }

    /// A source-type tab handle in the band registers here too
    /// (`StudioSourceTabDragHandleView`): it is drawn into the band by the same
    /// SwiftUI offset, so AppKit hit-tests a press on it to the hosting view and
    /// reads the drag that follows as a window move. Routed presses go to the
    /// tightest registered view under the pointer.
    static func registerWithBandRouter(_ view: NSView) {
        registeredSurfaces.add(view)
        installMouseDownMonitorIfNeeded()
        if let window = view.window {
            BandHoverTracker.install(on: window)
        }
    }

    static func unregisterFromBandRouter(_ view: NSView) {
        registeredSurfaces.remove(view)
    }

    /// SwiftUI can draw a representable above its hosting view's content bounds
    /// into the unified titlebar while AppKit still returns the hosting view from
    /// `hitTest(_:)`. Route only mouse-downs whose window-space point is inside a
    /// registered chrome control; every other click remains ordinary titlebar
    /// background and can still drag the window.
    private static func installMouseDownMonitorIfNeeded() {
        guard mouseDownMonitor == nil else { return }
        routerLogger.debug("Titlebar mouse router installed")
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let eventWindow = event.window else { return event }
            let target = registeredSurface(at: event.locationInWindow, in: eventWindow)
            let candidates = registeredSurfaces.allObjects
                .filter { $0.window === eventWindow }
                .map { surface in
                    let rect = surface.convert(surface.bounds, to: nil)
                    return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))\(surface.isHiddenOrHasHiddenAncestor ? " hidden" : "")"
                }
                .joined(separator: "; ")
            routerLogger.debug(
                "Titlebar mouse-down at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) in \(eventWindow.frame.width)x\(eventWindow.frame.height); registered: [\(candidates, privacy: .public)]; routed: \(target != nil)"
            )
            guard let target else { return event }
            // A control-click is a context click: it has to reach the SwiftUI
            // view underneath, where the tab's context menu lives.
            if target is TitlebarBandControlClickPassthrough,
               event.modifierFlags.contains(.control) { return event }
            target.mouseDown(with: event)
            return nil
        }
    }

    private static let routerLogger = Logger(subsystem: "com.foreverlm", category: "WindowChrome")

    static func registeredSurface(at point: NSPoint, in window: NSWindow) -> NSView? {
        registeredSurfaces.allObjects
            .filter { surface in
                surface.window === window
                    && !surface.isHiddenOrHasHiddenAncestor
                    && surface.convert(surface.bounds, to: nil).contains(point)
            }
            // Targets should not overlap, but prefer the tightest one if a
            // transitional layout briefly places two at the same point.
            .min { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
    }

    /// How far the pointer may wander from the press before the press is a drag
    /// rather than a click. Roughly the size of a band control, so ordinary
    /// hand jitter — which is most of what "the X doesn’t work" was — still
    /// clicks. Measured against the press point rather than by hit-testing the
    /// bounds: this view is drawn into the band by a SwiftUI offset, and a
    /// point converted back into its coordinate space does not land where the
    /// pointer visibly is, so a bounds test cancels on the first pixel of drift.
    private static let pressCancelDistance: CGFloat = 24

    private var pressOrigin: NSPoint?

    /// Consume the whole press here. Returning from `mouseDown` without taking
    /// the drags that follow is what lets AppKit reinterpret them as a titlebar
    /// window-move, so this tracking loop — not `mouseDownCanMoveWindow`, which
    /// AppKit ignores for a view inside SwiftUI’s hosting view — is what keeps a
    /// press on a band control from sliding the window.
    override func mouseDown(with event: NSEvent) {
        Self.routerLogger.debug("Titlebar surface mouseDown at \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y))")
        if menuProvider != nil {
            presentMenu()
            return
        }
        pressOrigin = event.locationInWindow
        isPressed = true
        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] tracked, stop in
            guard let self, let tracked else {
                stop.pointee = true
                return
            }
            switch tracked.type {
            case .leftMouseDragged:
                if self.dragDestination != nil, let origin = self.pressOrigin,
                   hypot(
                       tracked.locationInWindow.x - origin.x,
                       tracked.locationInWindow.y - origin.y
                   ) > Self.dragThreshold {
                    self.pendingDragEvent = tracked
                    stop.pointee = true
                    return
                }
                self.updatePress(with: tracked)
            case .leftMouseUp:
                stop.pointee = true
                self.finishPress()
            default:
                break
            }
        }
        if let dragEvent = pendingDragEvent {
            pendingDragEvent = nil
            isPressed = false
            pressOrigin = nil
            beginDrag(with: dragEvent)
        }
    }

    /// Starts a real dragging session from the event that crossed the
    /// threshold, carrying the same private pane payload the sidebar's rows
    /// and the tab strip carry, so any pane or edge destination takes it.
    private func beginDrag(with event: NSEvent) {
        guard let destination = dragDestination else { return }
        StudioDragVisibility.shared.begin(centerTab: destination.tab)
        let item = NSDraggingItem(
            pasteboardWriter: StudioCenterTabDragPayload.pasteboardItem(
                for: destination.tab,
                startsBlankChat: destination.startsBlankChat
            )
        )
        let ghost = studioDragGhostImage(title: destination.tab.title)
        item.setDraggingFrame(NSRect(origin: .zero, size: ghost.size), contents: ghost)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// Opens the control's menu hanging from its bottom edge. `popUp` runs its
    /// own tracking loop and returns once the menu has closed, so the pressed
    /// look lasts exactly as long as the menu is up. Also the accessibility
    /// press for a menu control, which has no pointer to anchor to.
    func presentMenu() {
        guard let menu = menuProvider?() else { return }
        isPressed = true
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.minX, y: bounds.maxY + 4),
            in: self
        )
        isPressed = false
    }

    /// Reached only when the view has no window to track in, as in tests.
    override func mouseDragged(with event: NSEvent) {
        updatePress(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishPress()
    }

    /// Track like a button: wandering off and back is a cancel-then-rearm, and
    /// wandering off and releasing does nothing.
    private func updatePress(with event: NSEvent) {
        guard let pressOrigin else { return }
        let moved = hypot(
            event.locationInWindow.x - pressOrigin.x,
            event.locationInWindow.y - pressOrigin.y
        )
        isPressed = moved <= Self.pressCancelDistance
    }

    private func finishPress() {
        let shouldFire = isPressed
        isPressed = false
        pressOrigin = nil
        if shouldFire { action() }
    }
}

struct TitlebarBandHitSurface: NSViewRepresentable {
    let action: () -> Void
    var menu: (() -> NSMenu)? = nil
    var dragDestination: StudioCenterTabDragPayload.Payload? = nil
    let help: String
    let onHoverChange: (Bool) -> Void
    let onPressedChange: (Bool) -> Void
    /// Receives the native view once it exists, so the SwiftUI accessibility
    /// action of a menu control can open the menu from the same anchor.
    var surfaceDidMount: (TitlebarBandHitSurfaceView) -> Void = { _ in }

    func makeNSView(context: Context) -> TitlebarBandHitSurfaceView {
        let view = TitlebarBandHitSurfaceView()
        // SwiftUI keeps the single accessibility element for this control; the
        // native view exists only for physical pointer delivery through the
        // titlebar mouse router above.
        view.setAccessibilityElement(false)
        surfaceDidMount(view)
        return view
    }

    func updateNSView(_ view: TitlebarBandHitSurfaceView, context: Context) {
        view.action = action
        view.menuProvider = menu
        view.dragDestination = dragDestination
        view.onHoverChange = onHoverChange
        view.onPressedChange = onPressedChange
        view.toolTip = help
    }

    /// Fill whatever the overlay proposes. A bare `NSView` has no intrinsic
    /// size, and letting SwiftUI fall back to one is how the previous native
    /// target ended up smaller than the wash it was supposed to cover.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TitlebarBandHitSurfaceView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// An icon button for the window's titlebar band, with `.buttonStyle(.hoverWash)`'s
/// look and AppKit's mouse handling. Every control on the chrome line — pane
/// close, swap, a strip tab's × — uses this instead of a `Button`; see
/// `TitlebarBandHitSurfaceView` for why a `Button` cannot work there.
struct TitlebarBandButton<Label: View>: View {
    let help: String
    var accessibilityLabel: String?
    var accessibilityValue: String?
    var accessibilityIdentifier: String?
    /// How far the wash — and so the hit surface — reaches past the label.
    /// Matches `HoverWashButtonStyle`'s default so a band control and an
    /// in-flow control of the same size have the same target.
    var washInset: CGFloat = 5
    /// The visual label's square before the hover wash grows its target. Every
    /// chrome-line control is an icon button; keeping this explicit makes the
    /// native surface's registered rectangle match the visible wash.
    var controlSize: CGFloat = StudioPanelChrome.centerTabCloseButtonSize
    /// Width of the label's slot when it is wider than it is tall (an icon with
    /// a disclosure chevron beside it). Defaults to `controlSize`.
    var controlWidth: CGFloat? = nil
    var cornerRadius: CGFloat = 8
    /// A disabled band control keeps its native surface — the press must still
    /// be consumed here rather than slide the window — but shows no wash and
    /// fires nothing. Reader's Back is the standing example: it is disabled
    /// until this pane has somewhere to go back to.
    var isEnabled: Bool = true
    /// Told when the pointer comes over the control and leaves it, for
    /// chrome that shows only under the pointer (`StudioHoverLinger`).
    var onHover: ((Bool) -> Void)? = nil
    /// Makes the control a drag source for this pane destination as well as a
    /// button: a still click fires `action`, a moved press drags.
    var dragDestination: StudioCenterTabDragPayload.Payload? = nil
    let action: () -> Void
    /// A menu control: a press opens this menu instead of firing `action`. Build
    /// it fresh per press so it reflects the current state. Use
    /// `NSHostingMenu` to keep authoring the items in SwiftUI.
    var menu: (() -> NSMenu)? = nil
    @ViewBuilder var label: () -> Label

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var surface = TitlebarBandSurfaceHandle()

    var body: some View {
        let targetWidth = (controlWidth ?? controlSize) + washInset * 2
        let targetHeight = controlSize + washInset * 2
        ZStack {
            // The native surface is the primary laid-out child. When it lived
            // in an overlay, SwiftUI painted it at the visible X but reported a
            // different window-space rectangle to AppKit, so the router could
            // not recognize the click it was meant to rescue.
            TitlebarBandHitSurface(
                action: isEnabled ? action : {},
                menu: isEnabled ? menu : nil,
                dragDestination: isEnabled ? dragDestination : nil,
                help: help,
                onHoverChange: { hovering in
                    isHovering = hovering
                    onHover?(hovering)
                },
                onPressedChange: { isPressed = $0 && isEnabled },
                surfaceDidMount: { surface.view = $0 }
            )
            .frame(width: targetWidth, height: targetHeight)
            // Out of the accessibility tree entirely, not just a non-element
            // NSView. With the surface merely `setAccessibilityElement(false)`,
            // SwiftUI still applied this control's label to it as an AppKit
            // override, and resolving that label asked the platform element
            // for its role, which asked the override for the label again:
            // the release build (0.5.0 38) died on 2026-09-01 in a stack
            // overflow of `AccessibilityNode.accessibilityLabel()` when an
            // assistive client read `studio.reader.closePane`.
            .accessibilityHidden(true)

            // The accessibility element lives on this SwiftUI-drawn child, never
            // on the container that also holds the native surface. When the
            // container carried it, SwiftUI backed the element with the
            // NSView — now the primary laid-out child — and the same label
            // loop came back on 2026-09-02 the moment an accessibility walk
            // read the control (Dev build, crash log 13:28:49). A SwiftUI node
            // has no AppKit override to recurse into.
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))

                label()
                    .opacity(isPressed ? 0.6 : 1)
                    .frame(width: controlWidth ?? controlSize, height: controlSize)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel ?? help)
            .accessibilityValue(accessibilityValue ?? "")
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .accessibilityAction(.default) {
                guard isEnabled else { return }
                if menu != nil {
                    surface.view?.presentMenu()
                } else {
                    action()
                }
            }
            // The one AX-visible node, so this is where an assistive client
            // reads the enabled state from.
            .disabled(!isEnabled)
        }
        .frame(width: targetWidth, height: targetHeight)
        // Report only the original icon slot to surrounding layout while the
        // native target and wash extend together into the reserved gutter.
        .padding(-washInset)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Weak handle to a band control's native surface, so the SwiftUI side can ask
/// it to present its menu. Not observable on purpose: nothing renders from it.
final class TitlebarBandSurfaceHandle {
    weak var view: TitlebarBandHitSurfaceView?
}

/// A confirmation a menu item wants shown before it acts. Items rendered by an
/// `NSHostingMenu` have no view in a window to present a dialog from, so the
/// control that opened the menu presents it on their behalf.
struct HostedMenuConfirmation {
    let title: String
    let confirmTitle: String
    var role: ButtonRole? = nil
    let action: () -> Void
}

private struct HostedMenuConfirmationKey: EnvironmentKey {
    static let defaultValue: ((HostedMenuConfirmation) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by a host that renders menu items through `NSHostingMenu`. A menu
    /// item that needs a confirmation calls it instead of presenting its own
    /// dialog; unset, the item presents as it would in a SwiftUI `Menu`.
    var hostedMenuConfirmation: ((HostedMenuConfirmation) -> Void)? {
        get { self[HostedMenuConfirmationKey.self] }
        set { self[HostedMenuConfirmationKey.self] = newValue }
    }
}

/// An AppKit-owned mouse surface for one center tab. SwiftUI's `.onDrag`
/// cannot reliably start a drag in the titlebar band: AppKit interprets the
/// mouse-down as a window move unless the deepest hit NSView refuses it. This
/// is laid out as the tab's full-size primary hit surface (not nested inside a
/// SwiftUI Button), so it owns the left mouse outright: a still click
/// activates the tab, a moved one starts a real NSDraggingSession
/// carrying the same plain-text payload the strip's SwiftUI drop delegates
/// already accept. Right-clicks walk the responder chain so the tab's
/// `.contextMenu` still opens; hover washes and tooltips keep working because
/// they ride the hosting view's tracking areas, not the hit test.
struct StudioCenterTabDragHandle: NSViewRepresentable {
    var title: String
    var isActive: Bool
    var payload: String
    var onActivate: () -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void
    var splitLeftEnabled: Bool
    var splitRightEnabled: Bool
    var onSplitLeft: () -> Void
    var onSplitRight: () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> StudioCenterTabDragHandleView {
        let view = StudioCenterTabDragHandleView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        update(view)
        return view
    }

    func updateNSView(_ nsView: StudioCenterTabDragHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: StudioCenterTabDragHandleView) {
        view.title = title
        view.isActive = isActive
        view.payload = payload
        view.onActivate = onActivate
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.splitLeftEnabled = splitLeftEnabled
        view.splitRightEnabled = splitRightEnabled
        view.onSplitLeft = onSplitLeft
        view.onSplitRight = onSplitRight
        view.onClose = onClose
        view.toolTip = "\(title); drag to the side to view side by side"
        view.setAccessibilityLabel(title)
        view.setAccessibilityValue(isActive ? "Selected" : "Not selected")
        view.setAccessibilityHelp("Drag to the side to view side by side")
    }
}

final class StudioCenterTabDragHandleView: NSView, NSDraggingSource {
    var title = ""
    var isActive = false
    var payload = ""
    var onActivate: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var splitLeftEnabled = false
    var splitRightEnabled = false
    var onSplitLeft: () -> Void = {}
    var onSplitRight: () -> Void = {}
    var onClose: () -> Void = {}

    private var pendingMouseDown: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// Tabs live in the titlebar band, so behave like toolbar buttons: respond
    /// to the click that also brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The strip hangs into the band by an offset, so AppKit never hit-tests a
    /// press to this view; the band's mouse router hands it over instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            TitlebarBandHitSurfaceView.unregisterFromBandRouter(self)
        } else {
            TitlebarBandHitSurfaceView.registerWithBandRouter(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A tab leaving its window mid-press (a closed pane) must not leave
        // the window pinned.
        WindowMoveLock.unlock(window)
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            pendingMouseDown = event
            return
        }
        // The pointer resting on the tab already held the window still
        // (`BandHoverTracker`); the press keeps it held until it is over: a
        // click, a cancelled press, or a drag session's end
        // (`draggingSession(_:endedAt:operation:)`), wherever the pointer goes.
        WindowMoveLock.lock(window)
        tabPressLogger.notice("center tab \(self.title, privacy: .public) mouseDown; \(tabPressOrigin(window), privacy: .public)")
        let result = trackTitlebarBandTabPress(event, in: window)
        switch result {
        case .click: tabPressLogger.notice("center tab press: click; \(tabPressOrigin(window), privacy: .public)")
        case .drag: tabPressLogger.notice("center tab press: drag; \(tabPressOrigin(window), privacy: .public)")
        case .cancelled: tabPressLogger.notice("center tab press: cancelled; \(tabPressOrigin(window), privacy: .public)")
        }
        switch result {
        case .click:
            WindowMoveLock.unlock(window)
            onActivate()
        case .drag(let dragged):
            beginTabDrag(with: dragged)
        case .cancelled:
            WindowMoveLock.unlock(window)
        }
    }

    /// Reached only when the view has no window to track in, as in tests.
    override func mouseDragged(with event: NSEvent) {
        guard let mouseDown = pendingMouseDown else { return }
        let start = mouseDown.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        pendingMouseDown = nil
        beginTabDrag(with: event)
    }

    private func beginTabDrag(with event: NSEvent) {
        onDragBegan()
        guard let tab = StudioCenterTabDragPayload.tab(from: payload) else {
            tabPressLogger.notice("center tab drag: payload did not decode")
            onDragEnded()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: StudioCenterTabDragPayload.pasteboardItem(for: tab))
        let ghost = dragGhostImage()
        item.setDraggingFrame(NSRect(origin: .zero, size: ghost.size), contents: ghost)
        // Start from the event that crossed the drag threshold. Passing the
        // original mouse-down here leaves AppKit free to continue the titlebar's
        // window-move tracking instead of transitioning into a drag session.
        beginDraggingSession(with: [item], event: event, source: self)
        tabPressLogger.notice("center tab drag session begun; \(tabPressOrigin(self.window), privacy: .public)")
    }

    override func mouseUp(with event: NSEvent) {
        if pendingMouseDown != nil {
            onActivate()
        }
        pendingMouseDown = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        pendingMouseDown = nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(title: "Split Left", action: #selector(splitLeft), enabled: splitLeftEnabled))
        menu.addItem(menuItem(title: "Split Right", action: #selector(splitRight), enabled: splitRightEnabled))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Close Tab", action: #selector(closeTab), enabled: true))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// A middle click closes the tab, as it does in a browser.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose()
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            onActivate()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate()
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tabPressLogger.notice("center tab drag ended, operation \(operation.rawValue); \(tabPressOrigin(self.window), privacy: .public)")
        WindowMoveLock.unlock(window)
        // Fires whether or not a drop target accepted, so a drag released over
        // nothing can't strand the strip in "dragging" state.
        onDragEnded()
    }

    private func menuItem(title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func splitLeft() {
        onSplitLeft()
    }

    @objc private func splitRight() {
        onSplitRight()
    }

    @objc private func closeTab() {
        onClose()
    }

    /// A simple pill ghost with the tab title — this view is transparent, so
    /// snapshotting it would produce an empty drag image.
    private func dragGhostImage() -> NSImage {
        studioDragGhostImage(title: title)
    }
}

/// The pill a pane drag shows under the pointer: the destination's title.
func studioDragGhostImage(title: String) -> NSImage {
    let text = title as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.labelColor,
    ]
    let textSize = text.size(withAttributes: attributes)
    let size = NSSize(width: min(textSize.width, 150) + 20, height: 24)
    return NSImage(size: size, flipped: false) { rect in
        let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        pill.fill()
        NSColor.separatorColor.setStroke()
        pill.stroke()
        text.draw(
            with: NSRect(
                x: 10,
                y: (rect.height - textSize.height) / 2,
                width: rect.width - 20,
                height: textSize.height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
        return true
    }
}

/// An AppKit-owned mouse surface for one source-type tab in the titlebar band.
///
/// Reordering the source types by dragging their icons is a SwiftUI `.onDrag`,
/// and in the band it lost every time: AppKit reads the mouse-down as the start
/// of a window move unless the deepest hit NSView refuses it, and a
/// `WindowDragBlocker` mounted behind the row never becomes that view while
/// interactive SwiftUI content sits on top of it — so the whole window slid
/// around instead of the icon. Laid out as the tab's topmost hit surface, this
/// owns the left mouse outright: a still click switches tabs, a moved one starts
/// a real `NSDraggingSession` carrying the same `.studioSidebarTab` payload the
/// row's SwiftUI drop delegates already accept. Right- and control-clicks fall
/// through (see `hitTest`) so the tab's `.contextMenu` still opens, and hover
/// washes keep working because they ride the hosting view's tracking areas
/// rather than the hit test.
struct StudioSourceTabDragHandle: NSViewRepresentable {
    var tab: StudioSidebarTab
    var toolTip: String
    var onActivate: () -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> StudioSourceTabDragHandleView {
        let view = StudioSourceTabDragHandleView()
        // The SwiftUI button underneath stays the single accessibility element:
        // it already carries the tab's label, its selected state, and a press
        // action that reaches the same `onActivate` work.
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(_ nsView: StudioSourceTabDragHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: StudioSourceTabDragHandleView) {
        view.tab = tab
        // SwiftUI's `.help` resolves through the hosting view, which no longer
        // owns this rect, so the tooltip has to be set on the handle itself.
        view.toolTip = toolTip
        view.onActivate = onActivate
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

final class StudioSourceTabDragHandleView: NSView, NSDraggingSource, TitlebarBandControlClickPassthrough {
    var tab: StudioSidebarTab?
    var onActivate: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}

    private var pendingMouseDown: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }

    /// Tabs live in the titlebar band, so behave like toolbar buttons: respond
    /// to the click that also brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Registered with the band's mouse router for the reason the pane tabs are
    /// (`StudioCenterTabDragHandleView`): a press here is otherwise a window move.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            TitlebarBandHitSurfaceView.unregisterFromBandRouter(self)
        } else {
            TitlebarBandHitSurfaceView.registerWithBandRouter(self)
        }
    }

    /// Own the left mouse only. A right-click — or a control-click, its
    /// equivalent — has to reach the SwiftUI button underneath, where the tab's
    /// context menu (per-type actions, labels, icon size, unpin) lives.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, isContextClick(event) { return nil }
        return super.hitTest(point)
    }

    private func isContextClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return true
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            pendingMouseDown = event
            return
        }
        switch trackTitlebarBandTabPress(event, in: window) {
        case .click: onActivate()
        case .drag(let dragged): beginTabDrag(with: dragged)
        case .cancelled: break
        }
    }

    /// Reached only when the view has no window to track in, as in tests.
    override func mouseDragged(with event: NSEvent) {
        guard let mouseDown = pendingMouseDown else { return }
        let start = mouseDown.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        pendingMouseDown = nil
        beginTabDrag(with: event)
    }

    private func beginTabDrag(with event: NSEvent) {
        guard let tab else { return }
        onDragBegan()
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: tab))
        let ghost = dragGhostImage(for: tab)
        item.setDraggingFrame(NSRect(origin: .zero, size: ghost.size), contents: ghost)
        // Start from the event that crossed the drag threshold. Passing the
        // original mouse-down here leaves AppKit free to continue the titlebar's
        // window-move tracking instead of transitioning into a drag session.
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingMouseDown != nil {
            onActivate()
        }
        pendingMouseDown = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Fires whether or not a drop target accepted, so a drag released over
        // nothing can't strand the row in its "dragging" state.
        onDragEnded()
    }

    /// Carries the raw value under the same type `sidebarTabDragProvider`
    /// registers, so `TabDropDelegate` accepts a drag from either path.
    private func pasteboardItem(for tab: StudioSidebarTab) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(
            tab.rawValue,
            forType: NSPasteboard.PasteboardType(UTType.studioSidebarTab.identifier)
        )
        return item
    }

    /// This view is transparent, so snapshotting it would drag an empty rect.
    /// Draw the tab's own icon and name in a pill instead.
    private func dragGhostImage(for tab: StudioSidebarTab) -> NSImage {
        let text = tab.rawValue as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        let glyph = tab.iconAsset.flatMap { NSImage(named: $0) }
        let glyphSide: CGFloat = glyph == nil ? 0 : 15
        let glyphGap: CGFloat = glyph == nil ? 0 : 5
        let textWidth = min(textSize.width, 150)
        let size = NSSize(width: textWidth + glyphSide + glyphGap + 20, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            pill.fill()
            NSColor.separatorColor.setStroke()
            pill.stroke()
            var textX: CGFloat = 10
            if let glyph {
                glyph.draw(in: NSRect(
                    x: textX,
                    y: (rect.height - glyphSide) / 2,
                    width: glyphSide,
                    height: glyphSide
                ))
                textX += glyphSide + glyphGap
            }
            text.draw(
                with: NSRect(
                    x: textX,
                    y: (rect.height - textSize.height) / 2,
                    width: textWidth,
                    height: textSize.height
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes
            )
            return true
        }
    }
}

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
    /// the part every pane used to re-derive by hand, and the part they got
    /// wrong: a row placed with `.padding(.top,` some number `)` sits below the
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

    /// The same close × for a pane with no center tab of its own — the
    /// notebook slot's picture — whose × runs `close`.
    func studioPaneCloseChrome(close: @escaping () -> Void) -> some View {
        modifier(StudioCenterTabCloseChrome(tab: nil, close: close))
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

/// A row hung in the titlebar band from the top of what it is laid over, on
/// the band's own chrome across that whole width. The band is the window's
/// chrome, as Codex's is, but the panes under it reach into it: a pane's
/// `.background(Color)` extends into the band (the top safe area) by default,
/// and a list or scroll view scrolls its rows up under it (both measured in a
/// stand-alone window with this titlebar, 2026-10-07). Backing every row that
/// hangs in the band covers both, so only the row shows there. Hit-testable,
/// as the opaque backing was: a press on it falls to the titlebar's window
/// drag, never to a row hidden underneath.
///
/// File-private on purpose: this is the one place that paints in the band, and
/// the only way another file hangs a row there is `studioBandOverlay`, so no
/// pane can paint its own backing across the band and show a different color
/// from the pane beside it (the chat's white title row next to the Review's
/// grey one, 2026-10-15).
fileprivate struct StudioBandRow<Row: View>: View {
    let band: CGFloat
    @ViewBuilder let row: () -> Row

    var body: some View {
        ZStack(alignment: .top) {
            StudioInsetCardStyle.chrome
                .frame(height: band)
            row()
        }
        .offset(y: -band)
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

private struct StudioChromeLineHeader<Header: View>: ViewModifier {
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
                        closeButton
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

    private var closeButton: some View {
        // A `Button` on the chrome line hands its mouse-down to the titlebar's
        // window drag; see `TitlebarBandHitSurfaceView`.
        TitlebarBandButton(
            help: "Close pane",
            accessibilityLabel: "Close pane",
            action: closePane
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

/// `@Observable` deliberately: nearly every row in the app (chat rows, notebook
/// rows, source rows, drop panels) consults this object. As an
/// `ObservableObject`, one drag beginning or ending invalidated every observer
/// at once — the sample traces showed a chat drag re-diffing the entire
/// Sources table. Per-property tracking means a row only re-renders when a
/// property it actually reads changes, and the guarded setters below keep
/// untouched properties from notifying at all.
@Observable
final class StudioDragVisibility {
    static let shared = StudioDragVisibility()

    private(set) var isDragging = false
    private(set) var draggedArticleIds: Set<String> = []
    private(set) var draggedGroupName: String?
    private(set) var draggedNotebookID: String?
    private(set) var draggedSessionID: String?
    private(set) var draggedCenterTab: StudioCenterTab?
    /// The Doc a Docs-list row or doc-title drag is carrying, beside the Docs
    /// pane itself.
    private(set) var draggedArtifactID: String?
    /// The Goal a Goals-tab row drag is carrying: the other rows draw an
    /// insertion line for it, and no source drop zone lights up.
    private(set) var draggedGoalID: String?
    /// The Space place a Space sidebar row or a kept shortcut is carrying:
    /// the icon strip draws it where it would land and keeps it there.
    private(set) var draggedRailShortcut: StudioRailShortcut?

    /// True while a whole pane is being dragged — Schedule, Docs, Notebooks, or
    /// New chat on its way to its own side-by-side pane. A pane drag carries no
    /// source payload, so every content drop zone (notebook rows, schedule days,
    /// the chat panel) must stay hidden: the only destination that can take it
    /// is the center area's edge split.
    ///
    /// A Docs-list row is the exception: its drag carries the Docs pane, so the
    /// edge split still opens Docs beside, and the doc itself, which the chat
    /// can take. Only a bare pane drag hides the content drop zones.
    ///
    /// A Space place on its way to the icon strip counts too, with or without
    /// a pane: it carries no source either, and the strip is its destination.
    var isPaneDrag: Bool { (draggedCenterTab != nil || draggedRailShortcut != nil) && draggedArtifactID == nil }

    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var mouseButtonReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var localMouseUpMonitor: Any?
    @ObservationIgnored private var globalMouseUpMonitor: Any?

    func begin(
        articleIDs: [String] = [],
        groupName: String? = nil,
        notebookID: String? = nil,
        sessionID: String? = nil,
        centerTab: StudioCenterTab? = nil,
        artifactID: String? = nil,
        goalID: String? = nil,
        railShortcut: StudioRailShortcut? = nil
    ) {
        setDragState(
            isDragging: true,
            draggedArticleIds: Set(articleIDs),
            draggedGroupName: groupName,
            draggedNotebookID: notebookID,
            draggedSessionID: sessionID,
            draggedCenterTab: centerTab,
            draggedArtifactID: artifactID,
            draggedGoalID: goalID,
            draggedRailShortcut: railShortcut
        )
        NSCursor.closedHand.set()
        installMouseUpMonitors()
        watchForMouseButtonRelease()
        scheduleReset(after: 8)
    }

    func endSoon() {
        // A mouse-up ends AppKit's dragging session before SwiftUI delivers the
        // destination's `perform` closure. Publishing `isDragging = false` in
        // that same event turn rebuilds every observing source row and drop
        // zone, which can remove the destination before it accepts the payload.
        // Keep the visual drag state alive for one short delivery window; an
        // accepted drop still calls this method, while the release monitors
        // cover drags that end over no destination.
        scheduleReset(after: 0.2)
    }

    func endNow() {
        resetTask?.cancel()
        resetTask = nil
        setDragState(
            isDragging: false,
            draggedArticleIds: [],
            draggedGroupName: nil,
            draggedNotebookID: nil,
            draggedSessionID: nil,
            draggedCenterTab: nil,
            draggedArtifactID: nil,
            draggedGoalID: nil,
            draggedRailShortcut: nil
        )
        mouseButtonReleaseTask?.cancel()
        mouseButtonReleaseTask = nil
        removeMouseUpMonitors()
        NSCursor.arrow.set()
    }

    private func setDragState(
        isDragging: Bool,
        draggedArticleIds: Set<String>,
        draggedGroupName: String?,
        draggedNotebookID: String?,
        draggedSessionID: String?,
        draggedCenterTab: StudioCenterTab?,
        draggedArtifactID: String?,
        draggedGoalID: String?,
        draggedRailShortcut: StudioRailShortcut?
    ) {
        // `@Observable` notifies a property's observers on every write, equal
        // value or not, so each assignment is guarded — a chat drag must not
        // re-render source rows that only read `draggedArticleIds`.
        if self.isDragging != isDragging { self.isDragging = isDragging }
        if self.draggedArticleIds != draggedArticleIds { self.draggedArticleIds = draggedArticleIds }
        if self.draggedGroupName != draggedGroupName { self.draggedGroupName = draggedGroupName }
        if self.draggedNotebookID != draggedNotebookID { self.draggedNotebookID = draggedNotebookID }
        if self.draggedSessionID != draggedSessionID { self.draggedSessionID = draggedSessionID }
        if self.draggedCenterTab != draggedCenterTab { self.draggedCenterTab = draggedCenterTab }
        if self.draggedArtifactID != draggedArtifactID { self.draggedArtifactID = draggedArtifactID }
        if self.draggedGoalID != draggedGoalID { self.draggedGoalID = draggedGoalID }
        if self.draggedRailShortcut != draggedRailShortcut { self.draggedRailShortcut = draggedRailShortcut }
    }

    private func scheduleReset(after seconds: TimeInterval) {
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            endNow()
        }
    }

    private func watchForMouseButtonRelease() {
        mouseButtonReleaseTask?.cancel()
        mouseButtonReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            while !Task.isCancelled {
                guard NSEvent.pressedMouseButtons != 0 else {
                    endSoon()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func installMouseUpMonitors() {
        removeMouseUpMonitors()
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                self?.endSoon()
            }
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endSoon()
            }
        }
    }

    private func removeMouseUpMonitors() {
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
    }
}

struct StudioDropZoneOverlay: View {
    let isActive: Bool
    var isVisible: Bool = false
    var title: String? = nil
    var systemImage: String = "arrow.down.doc"
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 6

    var body: some View {
        let shown = isActive || isVisible
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                Color.accentColor.opacity(isActive ? 0.95 : (shown ? 0.65 : 0)),
                style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: [7, 5])
            )
            .background(
                Color.accentColor.opacity(isActive ? 0.14 : (shown ? 0.06 : 0)),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .padding(inset)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.12), value: shown)
    }
}

/// Clears a stuck `onDrop(isTargeted:)` binding once the drag that set it is over.
///
/// AppKit tells a destination that a drag left it only while the session is
/// live. A drop that lands somewhere else, a drag cancelled with Escape, or a
/// row that SwiftUI rebuilt mid-drag can leave the last `isTargeted = true`
/// standing, and the row keeps its dashed drop outline until the next drag
/// happens to cross it. Every such drag ends with the mouse button released,
/// so that release is the reliable end signal: once no button is down the
/// binding is cleared after a short delivery window, long enough for the
/// destination's `perform` closure to run first (see
/// `StudioDragVisibility.endSoon`).
struct DropTargetWatchdogModifier: ViewModifier {
    @Binding var isTargeted: Bool
    @State private var watchdog: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: isTargeted) { _, targeted in
                watchdog?.cancel()
                watchdog = nil
                guard targeted else { return }
                watchdog = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { return }
                        guard NSEvent.pressedMouseButtons == 0 else { continue }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        if isTargeted { isTargeted = false }
                        return
                    }
                }
            }
            .onDisappear {
                watchdog?.cancel()
                watchdog = nil
            }
    }
}

extension View {
    /// Resets `isTargeted` when the drag that set it has ended without AppKit
    /// reporting the exit. Pair with any `onDrop(isTargeted:)` whose binding
    /// drives a visible highlight.
    func dropTargetWatchdog(_ isTargeted: Binding<Bool>) -> some View {
        modifier(DropTargetWatchdogModifier(isTargeted: isTargeted))
    }
}

// MARK: - Draggable panel layout

enum StudioPanelDefaultSizing {
    static let goldenRatio: CGFloat = 1.618_033_988_75

    /// The width the sidebar opens at so that every center pane is exactly
    /// φ times as wide as it. The row is sized as if an equal side column
    /// shared the window, which keeps the center φ times a side however wide
    /// the window is. Solving
    ///
    ///     window = 2·side + panes·φ·side + panes·divider
    ///
    /// for `side` is what keeps that ratio true at any window size — the old
    /// pinned point width held only at one width and drifted everywhere else
    /// (at 2560pt it had stretched the center to 2.5× the sides).
    ///
    /// Splitting the center narrows the sidebar, since the row now owes φ to
    /// two panes instead of one.
    static func goldenSideWidth(windowWidth: CGFloat, centerPaneCount: Int) -> CGFloat {
        let panes = CGFloat(max(1, centerPaneCount))
        let dividers = panes * StudioOuterPanelSizing.dividerWidth
        let side = (windowWidth - dividers) / (2 + panes * goldenRatio)
        return min(max(side, StudioNavigationRail.minRailWidth), StudioNavigationRail.maxRailWidth)
    }
}

/// Keeps adjacent panes usable while a divider moves. When the available span
/// cannot fit both minimums (for example in a genuinely narrow window), the
/// divider retains its ordinary hard bounds and the existing clipping behavior
/// remains the last resort.
enum StudioPaneDividerConstraint {
    static func clamp(
        _ proposed: CGFloat,
        hardLower: CGFloat,
        hardUpper: CGFloat,
        leadingMinimumWidth: CGFloat,
        trailingMinimumWidth: CGFloat,
        usableWidth: CGFloat
    ) -> CGFloat {
        let hardClamped = min(max(proposed, hardLower), hardUpper)
        guard usableWidth > 0,
              (hardUpper - hardLower) * usableWidth >= leadingMinimumWidth + trailingMinimumWidth
        else { return hardClamped }

        let lower = hardLower + leadingMinimumWidth / usableWidth
        let upper = hardUpper - trailingMinimumWidth / usableWidth
        guard lower <= upper else { return hardClamped }
        return min(max(hardClamped, lower), upper)
    }
}

/// Width contract for the center column: the pane minimum, and the gap a
/// divider between two center panes takes.
enum StudioOuterPanelSizing {
    static let dividerWidth: CGFloat = 10
    static let minimumContentWidth: CGFloat = 200
}

// MARK: - Center tab groups

/// Shared width contract for the center groups and the Studio shell's
/// reader-chat space policy. Keeping these values in one place prevents the
/// shell from deciding a layout fits while a pane is already clipping content.
enum StudioCenterTabGroupSizing {
    static let dividerWidth: CGFloat = 10
    static let minimumContentWidth: CGFloat = 200
    static let minimumChatContentWidth: CGFloat = 360
    /// The widest supported two-pane combination is Chat plus one ordinary
    /// workspace pane. Side panels can collapse, but the window itself must
    /// never become narrower than this chrome-free center arrangement.
    static let minimumWindowContentWidth = minimumChatContentWidth
        + minimumContentWidth
        + dividerWidth

    static func minimumWidth(for groups: [StudioCenterTabGroups.Group]) -> CGFloat {
        guard !groups.isEmpty else { return 0 }
        let contentWidth = groups.reduce(CGFloat.zero) { result, group in
            result + (ShellPlaces.descriptor(for: group.activeTab).role == .thread
                ? minimumChatContentWidth
                : minimumContentWidth)
        }
        return contentWidth + CGFloat(groups.count - 1) * dividerWidth
    }

    /// How much of one group's column the *enclosing* column clips off its
    /// trailing edge.
    ///
    /// The outer Reader column lays the groups out at the sum of their minima
    /// and clips the result at its real width, anchored leading. That clipping
    /// starts at the enclosing column's visible edge and eats leftwards, so it
    /// reaches only the groups whose columns extend past that edge — the last
    /// group first, and the ones before it only once the last is gone
    /// entirely. Handing the whole clipped amount to every group instead
    /// pushed the first pane's corner controls left by the full overflow, onto
    /// the traffic lights, while that pane was completely on screen.
    ///
    /// - Parameters:
    ///   - groupStart: The group's leading edge in the groups layout.
    ///   - groupWidth: The group's column width in that layout.
    ///   - totalWidth: The groups layout's full width (what the enclosing
    ///     column laid it out at).
    ///   - enclosingOverflow: How much of that width the enclosing column
    ///     clips away at the trailing edge.
    /// - Returns: The clipped width of this group, between zero and its width.
    static func clippedTrailingWidth(
        groupStart: CGFloat,
        groupWidth: CGFloat,
        totalWidth: CGFloat,
        enclosingOverflow: CGFloat
    ) -> CGFloat {
        let visibleEnd = totalWidth - max(0, enclosingOverflow)
        let groupEnd = groupStart + groupWidth
        return min(max(0, groupWidth), max(0, groupEnd - visibleEnd))
    }
}

extension StudioViewModel {
    /// Whether the Reader in `windowState` holds a video: a YouTube video, a
    /// video source, a generated explainer, or a meeting with a playable
    /// recording. Its tab then says Video, since a Reader names a document.
    func readerShowsVideo(in windowState: StudioWindowState) -> Bool {
        let article: StudioArticle?
        if let external = windowState.externalReaderPage {
            article = external.article
        } else {
            article = windowState.readerSourceID(fallingBackTo: selectedArticleId).flatMap { articlesById[$0] }
        }
        guard let article else { return false }
        if article.offersWatchedMarks || article.isYouTubeURL || GeneratedExplainerVideo.isVideoURL(article.url) {
            return true
        }
        return article.sourceType == .meeting
            && MeetingRecordingMedia.resolve(from: meetingArtifactsBySourceId[article.id] ?? []) != nil
    }
}

extension StudioViewModel {
    /// A Space place's name as the learner reads it: a team's, a space's and a
    /// list's are their own; every other place's is its fixed title.
    func spacePlaceTitle(_ destination: SpaceDestination) -> String {
        switch destination {
        case .team(let id):
            return teams.first { $0.id == id }?.name ?? "Space"
        case .space(let id):
            return pageSpaces.space(id)?.name ?? "Space"
        case .list(let id):
            return spaceLists.list(id)?.name ?? "List"
        default:
            return destination.title
        }
    }

    /// What the window's Space tab is called: the place it shows (Plan, Pages,
    /// a team's name), so two Space tabs in two windows read apart (product
    /// owner, 2026-11-08: "instead of just showing space here, in the tab
    /// title, maybe it should show what the exact space is"). All, the
    /// landing list, keeps the name Space.
    func spaceTabTitle(in windowState: StudioWindowState) -> String {
        let destination = SpaceDestination(key: windowState.spaceDestinationKey)
        return destination == .all ? StudioCenterTab.artifacts.title : spacePlaceTitle(destination)
    }
}

extension StudioCenterTab {
    /// What a tab in a strip is called: the Reader says Video while it holds
    /// one, and the Space names the place it shows (`spaceTabTitle`).
    func stripTitle(readerShowsVideo: Bool, spaceTitle: String? = nil) -> String {
        switch self {
        case .reader where readerShowsVideo: return "Video"
        case .artifacts: return spaceTitle ?? title
        default: return title
        }
    }

    /// The glyph a tab in a strip draws: the Reader draws a player while it
    /// holds a video.
    func stripSystemImage(readerShowsVideo: Bool) -> String {
        self == .reader && readerShowsVideo ? "play.rectangle" : ShellPlaces.descriptor(for: self).glyph
    }
}

private extension StudioCenterTab {
    /// Familiar, monochrome symbols help distinguish peer destinations without
    /// introducing another color system into the titlebar: the place
    /// registry's glyph (`ShellPlaces`).
    var systemImage: String { ShellPlaces.descriptor(for: self).glyph }
}

/// Where a dragged center tab would land.
enum StudioCenterTabDropTarget: Equatable {
    /// Insert before the tab at `index` in `group`.
    case tab(group: Int, index: Int)
    /// Append at the end of `group`'s strip.
    case stripEnd(group: Int)
    /// Split into a new group at the far edge of the center area.
    case edge(leading: Bool)
}

/// The private pasteboard contract used by center-tab drags. Keep the prefix
/// explicit so the edge destinations can reject ordinary text and source
/// drags without depending on SwiftUI's transient drag state.
enum StudioCenterTabDragPayload {
    private static let prefix = "centerTab:"
    /// Marks the rail's "New chat" row, which drags the Chat destination but
    /// means "a fresh conversation" — the same thing its click and its Open
    /// Beside menu item do. An ordinary Chat tab drag carries the loaded
    /// conversation and never this suffix.
    private static let blankChatSuffix = "?new"

    /// What a center-tab drag is asking for: which destination, and whether it
    /// should arrive on a blank conversation.
    struct Payload: Equatable {
        let tab: StudioCenterTab
        var startsBlankChat = false
    }

    /// A private type keeps native Reader/Chat text views from competing with
    /// the edge split destination for what used to look like an ordinary text
    /// drag. Keep UTF-8 text alongside it so the SwiftUI strip delegates retain
    /// compatibility with drags started by older builds.
    static let contentType = UTType(exportedAs: "com.foreverlm.studio-center-tab")
    static let pasteboardType = NSPasteboard.PasteboardType(contentType.identifier)
    static let dropTypes: [UTType] = [contentType, .utf8PlainText]

    static func string(for tab: StudioCenterTab, startsBlankChat: Bool = false) -> String {
        prefix + tab.rawValue + (startsBlankChat ? blankChatSuffix : "")
    }

    static func pasteboardItem(for tab: StudioCenterTab, startsBlankChat: Bool = false) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let payload = string(for: tab, startsBlankChat: startsBlankChat)
        item.setString(payload, forType: pasteboardType)
        item.setString(payload, forType: .string)
        return item
    }

    static func payload(from rawValue: String) -> Payload? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        var body = String(rawValue.dropFirst(prefix.count))
        var startsBlankChat = false
        if body.hasSuffix(blankChatSuffix) {
            body = String(body.dropLast(blankChatSuffix.count))
            startsBlankChat = true
        }
        guard let tab = StudioCenterTab(rawValue: body) else { return nil }
        return Payload(tab: tab, startsBlankChat: startsBlankChat)
    }

    static func tab(from rawValue: String) -> StudioCenterTab? {
        payload(from: rawValue)?.tab
    }
}

func studioCenterTabDragProvider(
    for tab: StudioCenterTab,
    startsBlankChat: Bool = false
) -> NSItemProvider {
    let provider = NSItemProvider()
    let payload = StudioCenterTabDragPayload.string(for: tab, startsBlankChat: startsBlankChat)
    let data = Data(payload.utf8)
    provider.registerDataRepresentation(
        forTypeIdentifier: StudioCenterTabDragPayload.contentType.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    provider.suggestedName = tab.title
    return provider
}

/// The drag a Docs-list or Sites-list row, or the title above an open doc, starts.
///
/// It carries the record's own pane — Docs for a doc, Sites for a site — so the
/// center area's edge split still opens that pane beside, what dragging a row
/// has always done, and the record itself, so a chat the drag lands on attaches
/// it the way its "Add to Chat" item does. The two ride on one provider: a
/// destination reads the type it registered for and never sees the other.
func studioArtifactDragProvider(for artifact: ArtifactRecord) -> NSItemProvider {
    let provider = studioCenterTabDragProvider(for: artifact.section.centerTab)
    let transfer = StudioArtifactTransfer(artifactID: artifact.id, title: artifact.title)
    if let data = try? JSONEncoder().encode(transfer) {
        // `.all`, not `.ownProcess`: this is the representation the chat's
        // SwiftUI `.onDrop` matches on, and every in-app source drag that
        // reaches that drop registers its payload `.all`. The center-tab
        // representation the provider already carries stays own-process — it
        // only feeds the AppKit edge-split destination.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioArtifact.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = artifact.title
    return provider
}

/// The pane created by an edge drop uses the same equal-width reset as the
/// live group layout. Keeping the preview calculation beside the drag contract
/// makes the outline match the final pane instead of being a generic edge cue.
enum StudioCenterTabSplitPreviewSizing {
    static func newPaneWidth(
        totalWidth: CGFloat,
        currentGroupCount: Int,
        dividerWidth: CGFloat,
        maximumGroupCount: Int = StudioCenterTabGroups.maximumGroupCount
    ) -> CGFloat {
        let nextGroupCount = currentGroupCount + 1
        guard currentGroupCount > 0,
              nextGroupCount <= maximumGroupCount else { return 0 }
        let usableWidth = totalWidth - CGFloat(nextGroupCount - 1) * dividerWidth
        return max(0, usableWidth / CGFloat(nextGroupCount))
    }

    /// The most one edge split zone may claim while a source is being dragged.
    ///
    /// A dragged source already has a destination inside every pane — Chat
    /// attaches it to the conversation, Reader opens it — so the edge zones
    /// have to leave the pane under the pointer a center band of its own. Sized
    /// to the pane they would create, the leading and trailing zones together
    /// cover the entire center area whenever there is a single group, which
    /// left a source dropped on Chat no way to reach Chat: the edge destination
    /// took every drop and opened a Reader beside it instead.
    static let minimumSourceEdgeZoneWidth: CGFloat = 22
    static let maximumSourceEdgeZoneWidth: CGFloat = 96
    static let sourceEdgeZoneFraction: CGFloat = 0.12

    static func sourceEdgeZoneWidth(totalWidth: CGFloat) -> CGFloat {
        min(
            max(totalWidth * sourceEdgeZoneFraction, minimumSourceEdgeZoneWidth),
            maximumSourceEdgeZoneWidth
        )
    }

    /// Whether the drag in flight carries something the pane under the pointer
    /// takes itself, so the edge zones must stay a gutter: a source, or a Doc
    /// or Site record. A Docs or Sites row's drag also names its pane, but the
    /// record rides along, so it counts as content; a bare pane drag, a chat
    /// drag, or a tab-strip drag does not.
    static func dragCarriesPaneContent(
        draggedArticleCount: Int,
        draggedArtifactID: Bool,
        draggedSessionID: Bool,
        draggingTab: Bool
    ) -> Bool {
        guard !draggedSessionID, !draggingTab else { return false }
        return draggedArticleCount > 0 || draggedArtifactID
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
    @ViewBuilder let tabContent: (StudioCenterTab) -> TabContent

    init(
        onSessionDropAtEdge: @escaping (ReviewSessionTransfer, Bool) -> Void = { _, _ in },
        @ViewBuilder tabContent: @escaping (StudioCenterTab) -> TabContent
    ) {
        self.onSessionDropAtEdge = onSessionDropAtEdge
        self.tabContent = tabContent
    }

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
                    let width = groupWidth(at: index, fractions: fractions, count: groups.count, totalWidth: geo.size.width)
                    groupColumn(
                        group,
                        at: index,
                        width: width,
                        enclosingClip: StudioCenterTabGroupSizing.clippedTrailingWidth(
                            groupStart: groupStart(at: index, fractions: fractions, count: groups.count, totalWidth: geo.size.width),
                            groupWidth: width,
                            totalWidth: geo.size.width,
                            enclosingOverflow: outerTrailingOverflow
                        )
                    )
                    if index < groups.count - 1 {
                        dividerHandle(at: index, groups: groups, totalWidth: geo.size.width)
                    }
                }
            }
            .overlay(alignment: .leading) {
                edgeSplitPreview(
                    leading: true,
                    groups: groups,
                    fractions: fractions,
                    totalWidth: geo.size.width
                )
            }
            .overlay(alignment: .trailing) {
                edgeSplitPreview(
                    leading: false,
                    groups: groups,
                    fractions: fractions,
                    totalWidth: geo.size.width
                )
            }
            .overlay(alignment: .leading) {
                edgeSplitZone(
                    leading: true,
                    groups: groups,
                    fractions: fractions,
                    totalWidth: geo.size.width
                )
            }
            .overlay(alignment: .trailing) {
                edgeSplitZone(
                    leading: false,
                    groups: groups,
                    fractions: fractions,
                    totalWidth: geo.size.width
                )
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
    }

    // MARK: Group column

    /// - Parameters:
    ///   - width: The group's column width in the groups layout.
    ///   - enclosingClip: How much of that column the outer Reader column clips
    ///     off its trailing edge (`StudioCenterTabGroupSizing.clippedTrailingWidth`).
    ///     Zero for every group that is fully on screen.
    private func groupColumn(
        _ group: StudioCenterTabGroups.Group,
        at index: Int,
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
            leadingReservation: index == 0 ? headerLeadingInset : 0,
            bandPassesThrough: !showsStrip,
            swapDestinationCount: StudioPaneSwap.centerDestinations.count
        ) {
            VStack(spacing: 0) {
                if titlebarBandHeight == nil && showsStrip {
                    strip(for: group, at: index)
                        .frame(height: StudioPanelChrome.headerHeight)
                }
                tabContent(group.activeTab)
                    .environment(\.studioPaneGroupID, group.id)
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
                StudioBandRow(band: band) {
                    strip(for: group, at: index)
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

    private func replacePane(at index: Int, with destination: StudioPaneDropDestination) {
        replaceTarget = nil
        vm.showDropped(destination, inPaneAt: index, in: windowState)
    }

    // MARK: Tab strip

    private func strip(
        for group: StudioCenterTabGroups.Group,
        at groupIndex: Int
    ) -> some View {
        let readerShowsVideo = vm.readerShowsVideo(in: windowState)
        let spaceTitle = vm.spaceTabTitle(in: windowState)
        return HStack(spacing: 2) {
            ForEach(Array(group.openTabs.enumerated()), id: \.element) { tabIndex, tab in
                if dropTarget == .tab(group: groupIndex, index: tabIndex) {
                    dropIndicatorCapsule
                }
                let isAlone = group.openTabs == [tab]
                let atCapacity = !windowState.centerTabGroups.canCreateDraggedGroup
                StudioCenterTabButton(
                    title: tab.stripTitle(readerShowsVideo: readerShowsVideo, spaceTitle: spaceTitle),
                    systemImage: tab.stripSystemImage(readerShowsVideo: readerShowsVideo),
                    isActive: group.activeTab == tab,
                    action: {
                        // This pane's copy, when the place stands in several.
                        windowState.focusedGroupID = group.id
                        vm.activateCenterTab(tab, in: windowState)
                    },
                    payload: StudioCenterTabDragPayload.string(for: tab),
                    onDragBegan: {
                        draggingTab = tab
                        draggingFromGroupID = group.id
                        dropTarget = nil
                    },
                    onDragEnded: {
                        draggingTab = nil
                        draggingFromGroupID = nil
                        dropTarget = nil
                    },
                    splitLeftEnabled: isAlone ? groupIndex > 0 : !atCapacity,
                    splitRightEnabled: isAlone ? groupIndex < windowState.centerTabGroups.groups.count - 1 : !atCapacity,
                    onSplitLeft: { vm.splitCenterTab(tab, fromGroup: group.id, towardRight: false, in: windowState) },
                    onSplitRight: { vm.splitCenterTab(tab, fromGroup: group.id, towardRight: true, in: windowState) },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            vm.closeCenterTab(tab, fromGroup: group.id, in: windowState)
                        }
                    }
                )
                .onDrop(of: StudioCenterTabDragPayload.dropTypes, delegate: StudioCenterTabDropDelegate(
                    target: .tab(group: groupIndex, index: tabIndex),
                    draggingTab: $draggingTab,
                    dropTarget: $dropTarget,
                    perform: { vm.moveCenterTab($0, fromGroup: draggingFromGroupID, toGroup: groupIndex, at: tabIndex, in: windowState) }
                ))
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
                        current: group.activeTab,
                        onSelect: { destination in
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
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: StudioPanelChrome.centerTabCloseButtonSize,
                        height: StudioPanelChrome.centerTabCloseButtonSize
                    )
            }
            if dropTarget == .stripEnd(group: groupIndex) {
                dropIndicatorCapsule
            }
            // The strip's empty tail appends a dragged tab to this group.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: StudioCenterTabDragPayload.dropTypes, delegate: StudioCenterTabDropDelegate(
                    target: .stripEnd(group: groupIndex),
                    draggingTab: $draggingTab,
                    dropTarget: $dropTarget,
                    perform: { vm.moveCenterTab($0, fromGroup: draggingFromGroupID, toGroup: groupIndex, at: .max, in: windowState) }
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
        // The leftmost pane's first tab starts after what the leading edge
        // holds: the traffic lights in the band, and in full screen ‹ › and
        // the sidebar toggle, which stand on this very row (product owner,
        // 2026-10-25: the Chat tab sat on the toggle).
        .padding(.leading, groupIndex == 0
            ? max(StudioTopBar.centerTabStripHorizontalPadding, headerLeadingInset)
            : StudioTopBar.centerTabStripHorizontalPadding)
        .padding(.trailing, StudioTopBar.centerTabStripHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(width: 3, height: 22)
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
                        // shows that doc. The row no longer selects itself as
                        // the drag begins — doing so swapped the open doc out
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

        guard let tab = draggingTab ?? dragVisibility.draggedCenterTab,
              let sourceIndex = groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return nil }

        // A destination dragged from the sidebar is taken by the pane under
        // the pointer, so the edge zones keep to a gutter and leave each pane
        // its middle, as they do for a source.
        let cap = draggingTab == nil && dragVisibility.isPaneDrag
            ? StudioCenterTabSplitPreviewSizing.sourceEdgeZoneWidth(totalWidth: totalWidth)
            : .infinity

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

/// An always-registered AppKit drop destination for a center area's far edge.
/// Center-tab drags already originate in AppKit, and keeping this endpoint in
/// the same drag system avoids SwiftUI registering a conditional destination
/// one run-loop turn after AppKit has selected candidates for the session.
private struct StudioCenterTabEdgeDropTarget: NSViewRepresentable {
    let onTargeted: (Bool) -> Void
    let onDrop: (StudioCenterTabDragPayload.Payload) -> Void
    let onSessionDrop: (ReviewSessionTransfer) -> Void
    let onSourceDrop: (String) -> Void

    func makeNSView(context: Context) -> StudioCenterTabEdgeDropView {
        let view = StudioCenterTabEdgeDropView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: StudioCenterTabEdgeDropView, context: Context) {
        update(nsView)
    }

    private func update(_ view: StudioCenterTabEdgeDropView) {
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.onSessionDrop = onSessionDrop
        view.onSourceDrop = onSourceDrop
    }
}

private final class StudioCenterTabEdgeDropView: NSView {
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (StudioCenterTabDragPayload.Payload) -> Void = { _ in }
    var onSessionDrop: (ReviewSessionTransfer) -> Void = { _ in }
    var onSourceDrop: (String) -> Void = { _ in }
    private var isTargeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            StudioCenterTabDragPayload.pasteboardType,
            NSPasteboard.PasteboardType(UTType.reviewSession.identifier),
            NSPasteboard.PasteboardType(UTType.studioSourceID.identifier),
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            StudioCenterTabDragPayload.pasteboardType,
            NSPasteboard.PasteboardType(UTType.reviewSession.identifier),
            NSPasteboard.PasteboardType(UTType.studioSourceID.identifier),
        ])
    }

    /// Dragging destinations are selected from registered view bounds, not
    /// ordinary mouse hit testing. Passing mouse events through preserves the
    /// rightmost pane's scrollbar and controls while the destination remains
    /// available for every drag session.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedPayload(from: sender.draggingPasteboard) != nil
                || draggedSession(from: sender.draggingPasteboard) != nil
                || draggedSourceID(from: sender.draggingPasteboard) != nil else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        return draggedPayload(from: sender.draggingPasteboard) == nil ? .copy : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedPayload(from: sender.draggingPasteboard) != nil
                || draggedSession(from: sender.draggingPasteboard) != nil
                || draggedSourceID(from: sender.draggingPasteboard) != nil else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        return draggedPayload(from: sender.draggingPasteboard) == nil ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        if let session = draggedSession(from: sender.draggingPasteboard) {
            onSessionDrop(session)
            return true
        }
        if let sourceID = draggedSourceID(from: sender.draggingPasteboard) {
            onSourceDrop(sourceID)
            return true
        }
        if let payload = draggedPayload(from: sender.draggingPasteboard) {
            onDrop(payload)
            return true
        }
        return false
    }

    private func setTargeted(_ targeted: Bool) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        onTargeted(targeted)
    }

    private func draggedPayload(from pasteboard: NSPasteboard) -> StudioCenterTabDragPayload.Payload? {
        let rawValue = pasteboard.string(forType: StudioCenterTabDragPayload.pasteboardType)
            ?? pasteboard.data(forType: StudioCenterTabDragPayload.pasteboardType)
                .flatMap { String(data: $0, encoding: .utf8) }
        guard let rawValue else { return nil }
        return StudioCenterTabDragPayload.payload(from: rawValue)
    }

    private func draggedSession(from pasteboard: NSPasteboard) -> ReviewSessionTransfer? {
        let type = NSPasteboard.PasteboardType(UTType.reviewSession.identifier)
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(ReviewSessionTransfer.self, from: data)
    }

    private func draggedSourceID(from pasteboard: NSPasteboard) -> String? {
        let type = NSPasteboard.PasteboardType(UTType.studioSourceID.identifier)
        let rawValue = pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
        let sourceID = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sourceID.isEmpty ? nil : sourceID
    }
}

// MARK: - AppKit drop catcher over a SwiftUI panel

/// An AppKit dragging destination laid over a SwiftUI panel, registered for
/// exactly the given types, that hands what it catches to a handler written
/// for `.onDrop(of:perform:)` — the same `[NSItemProvider]` shape, so one
/// `handleDrop` serves both routes.
///
/// Why a panel needs one: AppKit chooses a drag's destination among the AppKit
/// views under the pointer, deepest match first, and only falls back to the
/// SwiftUI destination (a `_PlatformDraggingDestinationView` registered for
/// `public.data` and `public.item`) when none of them takes the drag. A
/// `WKWebView` takes every drag over it whatever the pasteboard carries, and an
/// `NSTextView` takes any with a string or a file promise on it — which every
/// source drag has, since it offers a PDF, text or web-location file to the
/// browsers it can also be dropped in. So a doc or source let go over a chat's
/// transcript (web views) or its composer (a text view) never reached the
/// chat's `.onDrop`; only a drop on the panel's own chrome did. Laid over the
/// whole panel and registered for the exact payload types, this view is the
/// deepest match for those drags and takes them first, while a dragged string
/// still carries none of its types and reaches the text view as before. Its
/// `hitTest` returns nil, so it never sees a click or a scroll.
struct StudioDropCatcher: NSViewRepresentable {
    let types: [UTType]
    /// Leaves a drag alone that started on a view inside this one's own bounds
    /// (a picture dragged out of the chat's transcript): the chat has nothing
    /// to take from itself, and claiming it lit "Drop into this chat" the
    /// moment the drag began, wherever the pointer went after.
    var declinesDragsFromWithin = false
    let onTargeted: (Bool) -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    func makeNSView(context: Context) -> StudioDropCatcherView {
        let view = StudioDropCatcherView(types: types)
        update(view)
        return view
    }

    func updateNSView(_ nsView: StudioDropCatcherView, context: Context) {
        update(nsView)
    }

    private func update(_ view: StudioDropCatcherView) {
        view.declinesDragsFromWithin = declinesDragsFromWithin
        view.onTargeted = onTargeted
        view.onDrop = onDrop
    }
}

final class StudioDropCatcherView: NSView {
    var declinesDragsFromWithin = false
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: ([NSItemProvider]) -> Bool = { _ in false }

    let types: [UTType]
    private let pasteboardTypes: [NSPasteboard.PasteboardType]
    /// Whether the session in progress is one this view claimed at
    /// `draggingEntered`; a session it declined is never reported as targeted.
    private var ownsCurrentDrag = false

    init(types: [UTType]) {
        self.types = types
        pasteboardTypes = types.map { NSPasteboard.PasteboardType($0.identifier) }
        super.init(frame: .zero)
        registerForDraggedTypes(pasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StudioDropCatcherView is built in code")
    }

    /// Dragging destinations are chosen from registered view bounds, not from
    /// mouse hit testing, so this keeps every click and scroll for the panel
    /// underneath while the view stays a destination for every drag session.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func carriesPayload(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: pasteboardTypes) != nil
    }

    /// Whether the drag began on a view whose visible part lies inside this
    /// view's bounds. A source in another process, or one beside this view, is
    /// not within.
    private func startedWithin(_ sender: NSDraggingInfo) -> Bool {
        guard declinesDragsFromWithin,
              let source = sender.draggingSource as? NSView,
              let window, source.window === window else { return false }
        let visible = source.convert(source.visibleRect, to: nil)
        guard !visible.isEmpty else { return false }
        return convert(bounds, to: nil).contains(visible)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesPayload(sender), !startedWithin(sender) else {
            ownsCurrentDrag = false
            return []
        }
        ownsCurrentDrag = true
        onTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ownsCurrentDrag ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard ownsCurrentDrag else { return }
        onTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ownsCurrentDrag
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ownsCurrentDrag else { return false }
        let providers = studioDropItemProviders(from: sender.draggingPasteboard, types: types)
        onTargeted(false)
        guard !providers.isEmpty else { return false }
        return onDrop(providers)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard ownsCurrentDrag else { return }
        ownsCurrentDrag = false
        onTargeted(false)
    }
}

// MARK: - Dropping a destination on a pane

/// What a destination dragged from the sidebar names: a pane to show, or a
/// Space place that has no pane of its own and shows inside the Space.
enum StudioPaneDropDestination: Equatable {
    case tab(StudioCenterTabDragPayload.Payload)
    case place(StudioRailShortcut)
    /// A row of the notebook's Studio column: the output opens in the pane.
    case output(NotebookOutput)
}

/// The drag a row of a notebook's Studio column starts: a token naming the
/// output, so a pane it is dropped on opens that output there, as a click on
/// the row opens it in the pane last clicked in. The output itself stays in
/// this process (`register`), since only this app's panes take the drag.
@MainActor
enum NotebookOutputDragPayload {
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.notebookOutput.identifier)
    /// The rows dragged so far, by token. One drag at a time, so the last few
    /// are plenty; older ones are dropped as new ones come.
    private static var registered: [(token: String, output: NotebookOutput)] = []
    private static let kept = 8

    static func register(_ output: NotebookOutput) -> String {
        let token = UUID().uuidString
        registered.append((token, output))
        if registered.count > kept { registered.removeFirst(registered.count - kept) }
        return token
    }

    static func output(for token: String) -> NotebookOutput? {
        registered.last { $0.token == token }?.output
    }

    static func provider(for output: NotebookOutput) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(register(output).utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.notebookOutput.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = output.title
        return provider
    }

    /// The output a drag carries; nil for any other drag.
    static func output(on pasteboard: NSPasteboard) -> NotebookOutput? {
        guard let raw = pasteboard.string(forType: pasteboardType)
            ?? pasteboard.data(forType: pasteboardType).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return output(for: raw)
    }
}

extension StudioViewModel {
    /// The pane at `groupIndex` of `windowState` shows what a drop named, in
    /// place of what it showed. A Space place with no pane of its own shows
    /// inside the Space, which takes the pane first. A notebook's window is
    /// no different: its panes are the window's.
    func showDropped(_ destination: StudioPaneDropDestination, inPaneAt groupIndex: Int, in windowState: StudioWindowState) {
        StudioDragVisibility.shared.endNow()
        switch destination {
        case .tab(let payload):
            replaceCenterPane(
                at: groupIndex,
                with: payload.tab,
                startsBlankChat: payload.startsBlankChat,
                in: windowState
            )
            if payload.tab == .courses { openCoursesListInReader(in: windowState) }
        case .place(let shortcut):
            replaceCenterPane(at: groupIndex, with: .artifacts, in: windowState)
            switch shortcut {
            case .place(let place): showSpace(place, in: windowState)
            case .courses: openCoursesListInReader(in: windowState)
            }
        case .output(let output):
            Task { await openNotebookOutput(output, inPaneAt: groupIndex, in: windowState) }
        }
    }
}

/// An AppKit destination laid over one pane that takes a bare pane drag — a
/// rail or Space-sidebar destination, the "New chat" row, a kept shortcut —
/// and hands it to `onDrop`, so the pane under the pointer shows it. Any pane
/// is a destination, and what it showed stays one of its tabs
/// (`StudioCenterTabGroups.replacingPane`).
///
/// It declines a drag that carries content as well (a Docs row names its pane
/// but carries the Page, a chat row, a source): the pane's own destination,
/// such as the chat attaching it, takes those, as before. Whether a drag
/// carries content is read off the pasteboard, so the answer does not depend
/// on the drag's visibility state still being alive.
struct StudioPaneReplaceDropTarget: NSViewRepresentable {
    let onTargeted: (Bool) -> Void
    let onDrop: (StudioPaneDropDestination) -> Void

    func makeNSView(context: Context) -> StudioPaneReplaceDropView {
        let view = StudioPaneReplaceDropView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: StudioPaneReplaceDropView, context: Context) {
        update(nsView)
    }

    private func update(_ view: StudioPaneReplaceDropView) {
        view.onTargeted = onTargeted
        view.onDrop = onDrop
    }
}

final class StudioPaneReplaceDropView: NSView {
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (StudioPaneDropDestination) -> Void = { _ in }
    private var isTargeted = false

    private static let shortcutType = NSPasteboard.PasteboardType(UTType.studioRailShortcut.identifier)
    /// Types whose presence means the drag carries content for a pane to take.
    private static let contentTypes: [NSPasteboard.PasteboardType] = [
        UTType.studioArtifact, .studioArticle, .studioSourceID, .studioGroup, .reviewSession, .studioNotebook,
    ].map { NSPasteboard.PasteboardType($0.identifier) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([StudioCenterTabDragPayload.pasteboardType, Self.shortcutType, NotebookOutputDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([StudioCenterTabDragPayload.pasteboardType, Self.shortcutType, NotebookOutputDragPayload.pasteboardType])
    }

    /// Destinations are chosen from registered bounds, not mouse hit testing,
    /// so every click and scroll still reaches the pane underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        guard let destination = Self.destination(on: sender.draggingPasteboard) else { return false }
        onDrop(destination)
        return true
    }

    private func update(for sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.destination(on: sender.draggingPasteboard) != nil else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        return .move
    }

    private func setTargeted(_ targeted: Bool) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        onTargeted(targeted)
    }

    /// The destination a bare pane drag names; nil for a drag that carries
    /// content, or anything else. A pane wins over a place, since Pages, Sites
    /// and Courses carry both.
    static func destination(on pasteboard: NSPasteboard) -> StudioPaneDropDestination? {
        if let output = NotebookOutputDragPayload.output(on: pasteboard) {
            return .output(output)
        }
        guard pasteboard.availableType(from: contentTypes) == nil else { return nil }
        let tabType = StudioCenterTabDragPayload.pasteboardType
        if let raw = pasteboard.string(forType: tabType)
            ?? pasteboard.data(forType: tabType).flatMap({ String(data: $0, encoding: .utf8) }),
           let payload = StudioCenterTabDragPayload.payload(from: raw) {
            return .tab(payload)
        }
        if let raw = pasteboard.string(forType: shortcutType)
            ?? pasteboard.data(forType: shortcutType).flatMap({ String(data: $0, encoding: .utf8) }),
           let shortcut = StudioRailShortcut(key: raw) {
            return .place(shortcut)
        }
        return nil
    }
}

/// One item provider per pasteboard item, carrying the item's data for each of
/// `types` it has — the shape `.onDrop(of:perform:)` delivers, so a handler
/// written for it reads these unchanged. A source item offers both its transfer
/// and its bare id on the one provider, and the handler's own precedence
/// decides which it reads; an item carrying none of the types (a dragged
/// string, a bare pane) yields no provider. Data is read here, at the drop,
/// which is when a SwiftUI drag source is expected to supply what it promised.
func studioDropItemProviders(from pasteboard: NSPasteboard, types: [UTType]) -> [NSItemProvider] {
    (pasteboard.pasteboardItems ?? []).compactMap { item in
        let provider = NSItemProvider()
        var carriesAny = false
        for type in types {
            let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
            guard item.types.contains(pasteboardType),
                  let data = item.data(forType: pasteboardType) else { continue }
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            carriesAny = true
        }
        return carriesAny ? provider : nil
    }
}

/// One tab in a center group's strip.
private struct StudioCenterTabButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
    let payload: String
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let splitLeftEnabled: Bool
    let splitRightEnabled: Bool
    let onSplitLeft: () -> Void
    let onSplitRight: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @ScaledMetric(relativeTo: .caption) private var tabTextSize: CGFloat = 12

    /// The tab's ×, inside its trailing edge.
    private static let closeSize: CGFloat = 14

    /// Match the visual label's fixed metrics and give the representable an
    /// explicit non-zero frame. Letting an intrinsic-size-less NSView take its
    /// ideal size inside the ZStack can collapse its hit area to zero even
    /// while the SwiftUI label beside it remains visible.
    private var tabWidth: CGFloat {
        min(fullTextWidth, Self.maxTextWidth) + tabTextSize + 24 + Self.closeSize + 4
    }

    /// The most of a title a tab shows; a longer one runs off the edge.
    private static let maxTextWidth: CGFloat = 150

    private var fullTextWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: tabTextSize, weight: isActive ? .semibold : .medium)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        ZStack {
            // This AppKit surface is the actual laid-out tab, rather than a
            // representable nested in a SwiftUI Button overlay. Native views in
            // an offset titlebar overlay are otherwise liable to wind up behind
            // the hosting view in hit testing, where dragging moves the window.
            StudioCenterTabDragHandle(
                title: title,
                isActive: isActive,
                payload: payload,
                onActivate: action,
                onDragBegan: onDragBegan,
                onDragEnded: onDragEnded,
                splitLeftEnabled: splitLeftEnabled,
                splitRightEnabled: splitRightEnabled,
                onSplitLeft: onSplitLeft,
                onSplitRight: onSplitRight,
                onClose: onClose
            )
            .frame(width: tabWidth, height: 26)

            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: max(10, tabTextSize - 1), weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: tabTextSize, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    // The title is laid out whole and cut at the cap, with a
                    // soft fade instead of an ellipsis; short titles hug their text.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: min(fullTextWidth, Self.maxTextWidth), alignment: .leading)
                    .clipped()
                    .mask(alignment: .leading) {
                        if fullTextWidth > Self.maxTextWidth {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.85),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        } else {
                            Color.black
                        }
                    }
            }
                .padding(.leading, 9)
                .padding(.trailing, 9 + Self.closeSize + 4)
                .frame(width: tabWidth, height: 26, alignment: .leading)
                .background(StudioSelectionBackground(isSelected: isActive, isHovered: hovering))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // The strip rides in the titlebar band, where a SwiftUI Button
            // loses its clicks to the window drag (`TitlebarBandHitSurfaceView`).
            TitlebarBandButton(
                help: "Close Tab",
                accessibilityLabel: "Close \(title)",
                washInset: 2,
                controlSize: Self.closeSize,
                cornerRadius: 4,
                action: onClose
            ) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 8.5, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.closeSize, height: Self.closeSize)
            }
            .opacity(isActive || hovering ? 1 : 0)
            .padding(.trailing, 6)
            .frame(width: tabWidth, height: 26, alignment: .trailing)
        }
        .frame(width: tabWidth, height: 26)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .help(isActive ? title : "Show \(title); drag to the side to view side by side")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Shared drop handling for tab, strip-end, and edge-split targets. Validation
/// keys off the live `draggingTab` rather than inspecting the (async-only)
/// item payload, so source drags from the Sources panel fall straight through
/// to the panes underneath.
private struct StudioCenterTabDropDelegate: DropDelegate {
    let target: StudioCenterTabDropTarget
    @Binding var draggingTab: StudioCenterTab?
    @Binding var dropTarget: StudioCenterTabDropTarget?
    let perform: (StudioCenterTab) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingTab != nil
    }

    func dropEntered(info: DropInfo) {
        guard draggingTab != nil else { return }
        dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: draggingTab == nil ? .cancel : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTab = nil
            dropTarget = nil
        }
        guard let tab = draggingTab else { return false }
        perform(tab)
        return true
    }
}


extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

/// Reports a left-mouse-down inside this view's frame, without taking the
/// click: the pane a learner clicks in, whatever handles the click there — a
/// web view, a text view, a tab. A local monitor sees the press before AppKit
/// routes it, so no subview can swallow it first.
struct StudioPaneFocusObserver: NSViewRepresentable {
    let onFocus: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onFocus = onFocus
    }

    final class ObserverView: NSView {
        var onFocus: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                    // Never mutate SwiftUI state while a render may be
                    // tracking access.
                    Task { @MainActor [weak self] in self?.onFocus?() }
                    return event
                }
            }
        }

        deinit {
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// Reports every left-mouse-up the app dispatches while this view is in a
/// window. A local monitor sees the release that ends an ordinary click; the
/// release that ends a drag session never reaches it, which is exactly the
/// distinction the sidebar's deferred row open relies on.
struct MouseUpObserver: NSViewRepresentable {
    let onMouseUp: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onMouseUp = onMouseUp
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onMouseUp = onMouseUp
    }

    final class ObserverView: NSView {
        var onMouseUp: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                // Let AppKit finish the click first, and never mutate SwiftUI
                // state while a render may be tracking access.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.onMouseUp?()
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// Label for "more actions" menus: three plain vertical dots with no circle
/// or menu chevron, gaining a subtle highlight while the pointer is over the
/// dots themselves. Pair with `.menuIndicator(.hidden)` on the enclosing Menu.
/// The dots are drawn as circles rather than a rotated `ellipsis` symbol:
/// macOS snapshots a Menu's label into a flat image and drops
/// `rotationEffect`, which quietly rendered the dots horizontal again.
///
/// Host this in a `.menuStyle(.button)` + `.buttonStyle(.plain)` Menu, never
/// `.menuStyle(.borderlessButton)` (nor `.buttonStyle(.borderless)`). Those
/// styles size the control from the *text and image* they can extract out of
/// the label and ignore its SwiftUI layout entirely; a label built only from
/// shapes — which is exactly what the circles above make this — extracts to
/// nothing, so the menu collapses to an empty 6x14 box and draws nothing at
/// all. It is invisible *and* takes no space, so a row holding one is only as
/// tall as its text. Measured on macOS 26: `.borderlessButton` 6x14 against
/// `.button` + `.plain` 33.8x33.8, the same size as this label standing bare.
struct RowMoreActionsLabel: View {
    @Environment(\.uiZoomScale) private var uiZoomScale
    /// Draws a persistent fill and border so the dots read as a button before
    /// they are hovered. A row in a list borrows affordance from the row it
    /// sits in; a lone menu on an otherwise empty page header borrows nothing,
    /// and three unadorned 3pt dots at the far edge go unnoticed entirely.
    var bordered = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2.5 * uiZoomScale) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .frame(width: 3 * uiZoomScale, height: 3 * uiZoomScale)
            }
        }
        .foregroundStyle(.secondary)
        // The frame is the click target, not just the highlight: keep it
        // comfortably larger than the dots and scale it with zoom so the
        // target doesn't shrink relative to the rest of the UI.
        .frame(width: 26 * uiZoomScale, height: 26 * uiZoomScale)
        .background {
            RoundedRectangle(cornerRadius: 6 * uiZoomScale)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                .background {
                    if bordered {
                        RoundedRectangle(cornerRadius: 6 * uiZoomScale)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                }
        }
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: 6 * uiZoomScale)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// Makes an entire source row draggable when a drag provider is available.
struct SourceRowDragModifier<Preview: View>: ViewModifier {
    let itemProvider: (() -> NSItemProvider)?
    @ViewBuilder let preview: () -> Preview

    @ViewBuilder
    func body(content: Content) -> some View {
        if let itemProvider {
            // The main windows turn `.textSelection(.enabled)` on, so a press on
            // a row's title started a text selection instead of the drag (a
            // notebook source dragged toward the chat only highlighted its
            // title). A draggable row's words are not prose to select.
            content
                .contentShape(Rectangle())
                .textSelection(.disabled)
                .onDrag(itemProvider, preview: preview)
        } else {
            content
        }
    }
}

struct SourceDragPreview: View {
    let title: String
    let subtitle: String?
    let sourceType: StudioSourceType
    var isCompleted = false
    var isMissing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(sourceTypeColor.opacity(0.14))
                Image(systemName: isMissing ? "questionmark" : sourceTypeIcon)
                    .zoomedSystemFont(size: 18, weight: .medium)
                    .foregroundStyle(sourceTypeColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .opacity(0.92)
    }

    private var sourceTypeIcon: String {
        switch sourceType {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost: return "bubble.left"
        case .manual: return "link"
        }
    }

    private var sourceTypeColor: Color {
        switch sourceType {
        case .article, .unclassified: return .blue
        case .paper: return .purple
        case .podcast: return .orange
        case .book: return .green
        case .course: return .indigo
        case .meeting: return .teal
        case .video: return .red
        case .xPost: return .primary
        case .manual: return .secondary
        }
    }
}

enum StudioPlainTextDrop {
    static let types: [UTType] = [.utf8PlainText, .plainText, .text]

    static func loadString(from provider: NSItemProvider, completion: @escaping (String) -> Void) {
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            completion(raw)
        }
    }
}
