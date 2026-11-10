// The backdrop modifier behind the chat panel transcript.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// Backdrop for the scrolling transcript. In the docked Chat column and pop-out
/// window (`flat`) messages scroll directly on the panel's window background — the
/// clean, cardless look of Claude desktop / Codex. In the floating popover the
/// glass card stays, so the transcript reads against arbitrary Studio content behind it.
struct TranscriptSurface: ViewModifier {
    let flat: Bool

    func body(content: Content) -> some View {
        if flat {
            content
        } else {
            content.reviewGlassSurface(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: ReviewGlassStyle.composerTint,
                fallbackMaterial: .regularMaterial,
                fallbackBorder: Color.primary.opacity(0.08),
                shadowColor: Color.black.opacity(0.06),
                shadowRadius: 12,
                shadowY: 4
            )
        }
    }
}
