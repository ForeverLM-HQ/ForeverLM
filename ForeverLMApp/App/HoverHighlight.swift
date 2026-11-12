import SwiftUI

// MARK: - Wash ownership

/// Set by anything that already paints a hover wash behind a whole row.
///
/// A row that lights up on its own (`ArticleRow`) has to, because it is used bare
/// in the sources list where nothing else would. But hosts that wrap it in a wider
/// row — adding a badge, a more-actions menu, a remove button — need a wash that
/// covers the *whole* row, and then two washes of different size and radius stack
/// into a visible grey-on-grey double edge. The outer one wins: it is the one that
/// matches the hit area. Rows read this and skip painting their own.
private struct ContainerOwnsRowHoverWashKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var containerOwnsRowHoverWash: Bool {
        get { self[ContainerOwnsRowHoverWashKey.self] }
        set { self[ContainerOwnsRowHoverWashKey.self] = newValue }
    }
}

extension View {
    /// Declares that this view paints the hover wash for the rows inside it, so a
    /// nested row suppresses its own instead of doubling up. Applied automatically
    /// by `.buttonStyle(.hoverWash)` and `.hoverHighlight()`; call it directly when
    /// a container hand-rolls its row wash.
    func ownsRowHoverWash() -> some View {
        environment(\.containerOwnsRowHoverWash, true)
    }
}

// MARK: - Hover feedback

/// The geometry shared by the hover wash and the click target.
///
/// The wash reaches `-inset` points past the label so small icon buttons get a
/// comfortable-looking target without the label itself needing padding. Both the
/// paint and the `contentShape` use this same grown region, so whatever grey the
/// pointer lights up is exactly what a click lands on.
private struct HoverWash<S: Shape, Content: View>: View {
    let shape: S
    let inset: CGFloat
    let opacity: Double
    let isPressed: Bool
    let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isActive: Bool { isHovering && isEnabled }

    var body: some View {
        content
            .ownsRowHoverWash()
            // Grow, claim the grown box as the hit area, paint it, then shrink the
            // *reported* frame back so surrounding layout is untouched. Hits landing
            // in the overhang still resolve here: SwiftUI does not clip children to
            // a parent's frame for drawing or for hit testing.
            .padding(-inset)
            .contentShape(shape)
            .background { shape.fill(Color.primary.opacity(isActive ? opacity : 0)) }
            .padding(inset)
            .opacity(isPressed ? 0.6 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

/// Neutral hover wash shared by every button in the app.
///
/// AppKit's `.plain` and `.borderless` button styles paint no hover chrome, so
/// most of the app's buttons looked inert under the pointer. This style paints a
/// soft grey (white in dark mode) behind the label while the pointer is over it,
/// and — unlike a background applied *outside* a `Button` — makes that whole grey
/// clickable. A wash the pointer lights up but that swallows clicks around its
/// edge is the bug this style exists to prevent.
///
/// `tint` reproduces what `.borderless` used to contribute: it sets the ambient
/// foreground for the label. Labels that set their own `.foregroundStyle` still
/// win, so passing it is safe for icon buttons that already colour themselves.
struct HoverWashButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    var inset: CGFloat = -5
    var opacity: Double = 0.08
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HoverWash(
            shape: shape,
            inset: inset,
            opacity: opacity,
            isPressed: configuration.isPressed,
            content: label(of: configuration)
        )
    }

    /// Only overrides the foreground when a tint is asked for: `.plain` labels
    /// inherit their colour from context, and forcing one here would repaint
    /// every button that relies on that inheritance.
    @ViewBuilder
    private func label(of configuration: Configuration) -> some View {
        if let tint {
            configuration.label.foregroundStyle(tint)
        } else {
            configuration.label
        }
    }
}

extension ButtonStyle where Self == HoverWashButtonStyle {
    /// Chromeless button that lights up under the pointer, with the whole wash
    /// clickable. Replaces `.buttonStyle(.plain)` + `.hoverHighlight()`.
    static var hoverWash: HoverWashButtonStyle { HoverWashButtonStyle() }

    /// Hover wash with a rounded rect matching the app's small-control radius.
    ///
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the wash.
    ///   - inset: How far the wash — and the click target — extends past the
    ///     label. Negative grows it.
    ///   - opacity: Strength of the wash. Raise it for controls that sit on an
    ///     already-tinted surface, where the default reads too faintly.
    ///   - tint: Ambient foreground for the label, for buttons that previously
    ///     relied on `.borderless` to colour themselves.
    static func hoverWash(
        cornerRadius: CGFloat = 8,
        inset: CGFloat = -5,
        opacity: Double = 0.08,
        tint: Color? = nil
    ) -> HoverWashButtonStyle {
        HoverWashButtonStyle(
            shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)),
            inset: inset,
            opacity: opacity,
            tint: tint
        )
    }

    /// Hover wash using a caller-supplied shape, for controls whose own chrome is
    /// a capsule, circle, or other non-rectangular form.
    static func hoverWash<S: Shape>(
        in shape: S,
        inset: CGFloat = -5,
        opacity: Double = 0.08,
        tint: Color? = nil
    ) -> HoverWashButtonStyle {
        HoverWashButtonStyle(shape: AnyShape(shape), inset: inset, opacity: opacity, tint: tint)
    }
}

// MARK: - Non-button hover wash

private struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    let inset: CGFloat
    let opacity: Double

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isActive: Bool { isHovering && isEnabled }

    func body(content: Content) -> some View {
        content
            .ownsRowHoverWash()
            .padding(-inset)
            .contentShape(shape)
            .background { shape.fill(Color.primary.opacity(isActive ? opacity : 0)) }
            .padding(inset)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

extension View {
    /// Hover wash for things that are *not* a `Button` — rows driven by
    /// `.onTapGesture`, `Menu` labels, static affordances.
    ///
    /// Prefer `.buttonStyle(.hoverWash)` for buttons. On a `Button`, this modifier
    /// paints grey the button's own hit area does not cover, which is precisely
    /// the dead-edge problem it looks like it solves.
    func hoverHighlight(
        cornerRadius: CGFloat = 8,
        inset: CGFloat = -5,
        opacity: Double = 0.08
    ) -> some View {
        modifier(
            HoverHighlight(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                inset: inset,
                opacity: opacity
            )
        )
    }

    /// Non-button hover wash using a caller-supplied shape.
    func hoverHighlight<S: Shape>(
        in shape: S,
        inset: CGFloat = -5,
        opacity: Double = 0.08
    ) -> some View {
        modifier(HoverHighlight(shape: shape, inset: inset, opacity: opacity))
    }
}
