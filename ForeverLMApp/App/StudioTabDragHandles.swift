// The drag handles for centre tabs and source tabs, and the drag ghost image.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

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
    /// Double-click and the menu's Rename…; nil for a tab with no name of its own.
    var onRename: (() -> Void)? = nil

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
        view.onRename = onRename
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
    var onRename: (() -> Void)?

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
            // A double-click names the tab, as a terminal's does.
            if event.clickCount >= 2, let onRename {
                onRename()
            } else {
                onActivate()
            }
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
        if onRename != nil {
            menu.addItem(.separator())
            menu.addItem(menuItem(title: "Rename…", action: #selector(renameTab), enabled: true))
        }
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

    @objc private func renameTab() {
        onRename?()
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
