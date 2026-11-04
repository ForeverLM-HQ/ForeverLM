import AppKit
import SwiftUI

// The five marker colors carry a meaning (`SourceHighlightColor.meaning`).
// Everything the Mac draws for a color goes through here, so a swatch, a menu
// row and a tooltip never disagree about what a color says.

extension SourceHighlightColor {
    /// The swatch's sRGB color, opaque.
    var swatch: Color {
        let rgb = components
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// A swatch drawn for a menu row, where a SwiftUI shape cannot go: a dot in
    /// the marker's color, ringed when it is the one in use. Not a template
    /// image, so the menu does not tint it grey.
    func menuSwatchImage(isSelected: Bool) -> NSImage {
        let rgb = components
        let fill = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            fill.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
            if isSelected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                NSColor.labelColor.withAlphaComponent(0.75).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// One menu row per marker color, named by its meaning, the one in use ringed.
/// Used by the highlight list's Color menu and its filter.
struct HighlightColorMenuRow: View {
    let color: SourceHighlightColor
    var isSelected = false
    var count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                if let count {
                    Text("\(color.meaning)  \(count)")
                } else {
                    Text(color.meaning)
                }
            } icon: {
                Image(nsImage: color.menuSwatchImage(isSelected: isSelected))
            }
        }
    }
}
