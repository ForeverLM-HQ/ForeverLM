import AppKit
import SwiftUI

/// A chat's picture, popped out beside the conversation it came from.
///
/// A figure squeezed into the transcript's column is unreadable, and the
/// full-window lightbox hides the question it was shown for. The figure's
/// Open beside puts the same bytes in a pane of their own: the notebook's
/// document slot, so the question stays on the left and the picture is big on
/// the right (`ChatPicturePane`), and in a window with no notebook, a small
/// window the learner can put where they like (`ChatPictureWindow`).
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

/// The notebook's document slot while it holds `.picture`: the picture the
/// window's chat popped out, and the × that gives the slot back.
struct ChatPicturePane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    var body: some View {
        Group {
            if let picture = windowState.dockedPicture {
                ChatPictureView(picture: picture)
            } else {
                // A place restored by ‹ › after the window dropped the bytes.
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .studioPaneCloseChrome {
            vm.closePictureInNotebook(in: windowState)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture")
        .accessibilityIdentifier("notebook.picture")
    }
}

/// A picture popped out where there is no notebook to dock it in: one small
/// window, reused for the next picture sent beside, closed like any window.
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
