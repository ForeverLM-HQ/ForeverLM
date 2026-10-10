import SwiftUI
import AppKit

// MARK: - Liquid Glass

enum ReviewGlassStyle {
    static let silverTint = dynamicTint(light: 0.98, dark: 0.16, opacity: 0.94)
    static let composerTint = dynamicTint(light: 0.99, dark: 0.18, opacity: 0.88)
    static let shellCornerRadius: CGFloat = 22

    /// Glass tints must resolve per-appearance at draw time; a plain `Color(white:)`
    /// stays light even when the window is in dark mode.
    private static func dynamicTint(light: CGFloat, dark: CGFloat, opacity: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }).opacity(opacity)
    }

    static var contentBackdrop: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.90)
    }

    static var toolbarBackdrop: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.82)
    }
}

@available(macOS 26.0, iOS 26.0, *)
private func reviewLiquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

extension View {
    /// Applies Apple's Liquid Glass to a surface on macOS 26 / iOS 26 and newer,
    /// with a material-based fallback (background + hairline border) on older systems
    /// so the chat keeps a coherent look across OS versions.
    @ViewBuilder
    func reviewGlassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackMaterial: Material = .regularMaterial,
        fallbackBorder: Color = .clear,
        shadowColor: Color = .clear,
        shadowRadius: CGFloat = 0,
        shadowY: CGFloat = 0
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self
                .glassEffect(reviewLiquidGlass(tint: tint, interactive: interactive), in: shape)
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        } else {
            self
                .background(fallbackMaterial, in: shape)
                .overlay(shape.strokeBorder(fallbackBorder, lineWidth: 1))
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        }
    }
}
