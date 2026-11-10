// The AppKit drop targets over a pane and the destinations a drop can name.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit
import OSLog

/// An always-registered AppKit drop destination for a center area's far edge.
/// Center-tab drags already originate in AppKit, and keeping this endpoint in
/// the same drag system avoids SwiftUI registering a conditional destination
/// one run-loop turn after AppKit has selected candidates for the session.
struct StudioCenterTabEdgeDropTarget: NSViewRepresentable {
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

final class StudioCenterTabEdgeDropView: NSView {
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
