import AppKit
import SwiftUI
import WebKit

/// A chat's picture, popped out beside the conversation it came from.
///
/// A figure squeezed into the transcript's column is unreadable, and the
/// full-window lightbox hides the question it was shown for. The figure's
/// Open beside puts the same bytes in a small window the learner can put
/// where they like (`ChatPictureWindow`), so the question stays in view and
/// the picture is big beside it.
///
/// The picture is the lightbox's magnifying view: fit on entry, a click zooms
/// in around the point and a second click fits it again, a pinch or ⌘-scroll
/// magnifies freely. A click beside the picture does nothing here, since the
/// pane is not a backdrop to dismiss.
struct ChatPictureView: View {
    let picture: DockedChatPicture

    @State private var didCopy = false

    private var image: ChatSourceImage {
        ChatSourceImage(data: picture.data, mediaType: picture.mediaType)
    }

    var body: some View {
        ZStack {
            if let nsImage = NSImage(data: picture.data) {
                ChatImageZoomView(image: nsImage, onBackdropClick: {})
                    .id(picture.id)
                    .accessibilityLabel(picture.title ?? "Picture")
            } else {
                Text("Picture unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { footer }
    }

    /// The caption and Copy, along the foot where the lightbox puts its own.
    private var footer: some View {
        HStack(spacing: 10) {
            if let title = picture.title {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
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
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                    .frame(height: 22)
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -3, opacity: 0.14))
            .keyboardShortcut("c", modifiers: .command)
            .help("Copy image")
            .accessibilityLabel("Copy image")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

/// A picture popped out beside its chat: one small window, reused for the
/// next picture sent beside, closed like any window.
@MainActor
enum ChatPictureWindow {
    private static var current: NSWindow?

    static func present(_ picture: DockedChatPicture) {
        let content = NSHostingView(rootView: ChatPictureView(picture: picture))
        if let window = current, window.isVisible {
            window.contentView = content
            window.title = picture.title ?? "Picture"
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = picture.title ?? "Picture"
        window.contentView = content
        window.setFrameAutosaveName("chat.pictureWindow")
        if !window.setFrameUsingName("chat.pictureWindow") { window.center() }
        window.setAccessibilityIdentifier("chat.pictureWindow")
        window.makeKeyAndOrderFront(nil)
        current = window
    }
}

/// Open Beside in a chat picture's right-click menu. The figure carries no
/// buttons for it (or for Copy, which WebKit's own Copy Image already does);
/// the page remembers the picture the menu was raised over
/// (`mac-picture-menu.js`) and posts `openSourceImageBeside` for it.
@MainActor
enum ChatPictureMenu {
    /// Adds Open Beside under WebKit's Copy Image, which is there only when
    /// the pointer is over a picture. Returns the item's target, which the
    /// caller holds until the next menu opens (`NSMenuItem.target` is weak).
    static func insertOpenBeside(in menu: NSMenu, webView: WKWebView) -> MenuActionTarget? {
        guard let copyIndex = menu.items.firstIndex(where: {
            $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage"
        }) else { return nil }
        let target = MenuActionTarget { [weak webView] in
            webView?.evaluateJavaScript("window.openContextPictureBeside && window.openContextPictureBeside(); undefined;")
        }
        let item = NSMenuItem(title: "Open Beside", action: #selector(MenuActionTarget.fire), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Open Beside")
        item.target = target
        menu.insertItem(item, at: copyIndex + 1)
        return target
    }
}
