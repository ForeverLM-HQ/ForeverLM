import AppKit
import SwiftUI

/// A picture from the chat, full-window.
///
/// The transcript squeezes every picture into its column, which makes a dense
/// figure or a page screenshot unreadable; a click puts it on a dark backdrop
/// over the whole window, the way the reader's figures open. The backdrop is
/// its own borderless window, a child of the window the click landed in: each
/// message row is a separate web view, so a backdrop drawn inside a page could
/// cover only that row.
///
/// Fit on entry; a click on the picture zooms in around the point clicked and
/// a second click fits it again; a pinch or ⌘-scroll magnifies freely; a click
/// beside the picture, Escape or ✕ closes; ⌘C copies the same bytes the Copy
/// button on the figure does.
@MainActor
enum ChatImageLightbox {
    static func present(_ image: ChatSourceImage, title: String?, over host: NSWindow?) {
        guard let nsImage = NSImage(data: image.data) else { return }
        guard let host = host ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        ChatImageLightboxWindow.show(image: image, nsImage: nsImage, title: title, over: host)
    }

    /// The magnification at which the whole picture is on screen. A small
    /// picture is enlarged to fill, but no further than two points per pixel:
    /// past that a thumbnail is a blur, not a bigger picture.
    nonisolated static func fitMagnification(viewport: CGSize, document: CGSize) -> CGFloat {
        guard document.width > 0, document.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / document.width, viewport.height / document.height, 2)
    }

    /// Where a click on the picture takes the magnification: from the fit to a
    /// closer look, and from anywhere else back to the fit. A fit that already
    /// shows the pixels at one point each or better zooms to double instead of
    /// a no-op.
    nonisolated static func toggledMagnification(current: CGFloat, fit: CGFloat, maximum: CGFloat) -> CGFloat {
        let zoomed = min(max(1, fit * 2), maximum)
        return abs(current - fit) < 0.01 ? zoomed : fit
    }
}

/// The lightbox window: borderless, transparent, the size of its host, closed
/// by Escape from anywhere in it.
final class ChatImageLightboxWindow: NSWindow {
    @MainActor private static var current: ChatImageLightboxWindow?

    private weak var host: NSWindow?
    private var hostObservers: [NSObjectProtocol] = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @MainActor
    static func show(image: ChatSourceImage, nsImage: NSImage, title: String?, over host: NSWindow) {
        current?.dismiss()
        let window = ChatImageLightboxWindow(host: host)
        let content = ChatImageLightboxView(
            image: image,
            nsImage: nsImage,
            title: title,
            dismiss: { [weak window] in window?.dismiss() }
        )
        // The backdrop is dark whatever the app's appearance, so every wash
        // and label in it is drawn for a dark surface.
        .environment(\.colorScheme, .dark)
        window.contentView = NSHostingView(rootView: content)
        window.appearance = NSAppearance(named: .darkAqua)
        host.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        current = window
    }

    private init(host: NSWindow) {
        self.host = host
        super.init(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityIdentifier("chat.imageLightbox")

        // A child window follows its parent's moves but not its resizes, and a
        // parent that closes takes the picture with it.
        let center = NotificationCenter.default
        hostObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.matchHostFrame() }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.matchHostFrame() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            },
        ]
    }

    private func matchHostFrame() {
        guard let host else { return }
        setFrame(host.frame, display: true)
    }

    override func keyDown(with event: NSEvent) {
        // Escape (53) closes from anywhere in the window, whichever view has
        // focus; everything else goes where a key normally goes.
        if event.keyCode == 53 {
            dismiss()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    func dismiss() {
        for observer in hostObservers { NotificationCenter.default.removeObserver(observer) }
        hostObservers = []
        let host = self.host
        host?.removeChildWindow(self)
        orderOut(nil)
        close()
        if Self.current === self { Self.current = nil }
        host?.makeKeyAndOrderFront(nil)
    }
}

/// The lightbox's content: the picture on its backdrop, Copy and ✕ in the top
/// corner, the caption under it.
struct ChatImageLightboxView: View {
    let image: ChatSourceImage
    let nsImage: NSImage
    let title: String?
    let dismiss: () -> Void

    @State private var didCopy = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ChatImageZoomView(image: nsImage, onBackdropClick: dismiss)
                .accessibilityLabel(title ?? "Picture")
            HStack(spacing: 4) {
                Button {
                    guard image.copyToPasteboard() else { return }
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1400))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                        .frame(height: 22)
                }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy image")
                .accessibilityLabel("Copy image")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -3, opacity: 0.22))
            .padding(6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(14)
        }
        .overlay(alignment: .bottom) {
            if let title {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black.opacity(0.86))
        .ignoresSafeArea()
    }
}

/// The picture in a magnifying scroll view: pinch and ⌘-scroll zoom natively,
/// the picture stays centred while it is smaller than the window, a click on
/// it toggles between fit and a closer look around the click, and a click on
/// the backdrop beside it reports out so the lightbox can close.
struct ChatImageZoomView: NSViewRepresentable {
    let image: NSImage
    let onBackdropClick: () -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.onBackdropClick = onBackdropClick
        scroll.setImage(image)
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        scroll.onBackdropClick = onBackdropClick
        if scroll.imageView.image !== image { scroll.setImage(image) }
    }

    final class ZoomScrollView: NSScrollView {
        let imageView = NSImageView()
        var onBackdropClick: (() -> Void)?
        private var needsInitialFit = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            drawsBackground = false
            hasVerticalScroller = true
            hasHorizontalScroller = true
            autohidesScrollers = true
            scrollerStyle = .overlay
            allowsMagnification = true
            minMagnification = 0.05
            maxMagnification = 8
            contentView = CenteringClipView()
            contentView.drawsBackground = false
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageAlignment = .alignCenter
            imageView.isEditable = false
            imageView.animates = false
            documentView = imageView
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            click.numberOfClicksRequired = 1
            addGestureRecognizer(click)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("ZoomScrollView is built in code") }

        /// The document is the picture at one point per pixel, so magnification
        /// 1 shows every pixel; a picture whose representations disagree, or a
        /// vector one, is sized by its own point size.
        func setImage(_ image: NSImage) {
            imageView.image = image
            var pixelSize: CGSize?
            for representation in image.representations {
                let candidate = CGSize(width: CGFloat(representation.pixelsWide), height: CGFloat(representation.pixelsHigh))
                guard candidate.width > 0, candidate.height > 0 else { continue }
                if let best = pixelSize, best.width * best.height >= candidate.width * candidate.height { continue }
                pixelSize = candidate
            }
            let size = pixelSize ?? image.size
            imageView.frame = NSRect(origin: .zero, size: size)
            needsInitialFit = true
            fitIfNeeded()
        }

        override func layout() {
            super.layout()
            fitIfNeeded()
        }

        private var fitMagnification: CGFloat {
            ChatImageLightbox.fitMagnification(viewport: contentView.frame.size, document: imageView.frame.size)
        }

        private func fitIfNeeded() {
            guard needsInitialFit, contentView.frame.width > 0, contentView.frame.height > 0 else { return }
            needsInitialFit = false
            magnification = fitMagnification
            centerDocument()
        }

        private func centerDocument() {
            let visible = contentView.bounds.size
            let document = imageView.frame.size
            contentView.scroll(to: NSPoint(
                x: (document.width - visible.width) / 2,
                y: (document.height - visible.height) / 2
            ))
            reflectScrolledClipView(contentView)
        }

        @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
            let inDocument = recognizer.location(in: imageView)
            guard imageView.bounds.contains(inDocument) else {
                onBackdropClick?()
                return
            }
            let fit = fitMagnification
            let next = ChatImageLightbox.toggledMagnification(current: magnification, fit: fit, maximum: maxMagnification)
            if abs(next - fit) < 0.01 {
                setMagnification(next, centeredAt: NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY))
            } else {
                setMagnification(next, centeredAt: inDocument)
            }
        }
    }

    /// Keeps a document smaller than the clip view in its middle rather than
    /// pinned to a corner, at every magnification.
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            guard let document = documentView else { return rect }
            let frame = document.frame
            if rect.width > frame.width {
                rect.origin.x = frame.midX - rect.width / 2
            }
            if rect.height > frame.height {
                rect.origin.y = frame.midY - rect.height / 2
            }
            return rect
        }
    }
}
