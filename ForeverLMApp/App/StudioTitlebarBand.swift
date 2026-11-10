// The titlebar band: the hover tracker, tab presses, the hit surface and the band button.

import SwiftUI
import Combine
import AppKit
import OSLog

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

let tabPressLogger = Logger(subsystem: "com.foreverlm", category: "TabPress")

func tabPressOrigin(_ window: NSWindow?) -> String {
    guard let frame = window?.frame else { return "no window" }
    return "window at \(Int(frame.origin.x)),\(Int(frame.origin.y))"
}

/// Marks a registered band view whose control-clicks are not its own: they pass
/// on to the SwiftUI view underneath, whose `.contextMenu` they open.
protocol TitlebarBandControlClickPassthrough: NSView {}

/// The one mouse surface for a control that lives in the titlebar band.
///
/// A press on a band control slides the whole window by default: measured on the
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
