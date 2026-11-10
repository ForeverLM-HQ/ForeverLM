// The centre tab button and drop delegate, the pane focus observer and the source row drag views.

import SwiftUI
import Combine
import AppKit

/// One tab in a center group's strip.
struct StudioCenterTabButton: View {
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
    var onRename: (() -> Void)? = nil

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
                onClose: onClose,
                onRename: onRename
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
struct StudioCenterTabDropDelegate: DropDelegate {
    let target: StudioCenterTabDropTarget
    @Binding var draggingTab: StudioCenterTab?
    @Binding var dropTarget: StudioCenterTabDropTarget?
    /// A tab dragged here from another window's strip, which this window's
    /// `draggingTab` never hears of.
    let arriving: () -> StudioCenterTabWindowDrag.Origin?
    let perform: (StudioCenterTab) -> Void
    let receive: (StudioCenterTabWindowDrag.Origin) -> Void

    private var takesDrag: Bool { draggingTab != nil || arriving() != nil }

    func validateDrop(info: DropInfo) -> Bool {
        takesDrag
    }

    func dropEntered(info: DropInfo) {
        guard takesDrag else { return }
        dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: takesDrag ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTab = nil
            dropTarget = nil
        }
        if let tab = draggingTab {
            perform(tab)
            return true
        }
        guard let origin = arriving() else { return false }
        receive(origin)
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
                    .fill(sourceType.tintColor.opacity(0.14))
                Image(systemName: isMissing ? "questionmark" : sourceType.symbolName)
                    .zoomedSystemFont(size: 18, weight: .medium)
                    .foregroundStyle(sourceType.tintColor)
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
}
