import SwiftUI

/// Shared visual foundations for the iPhone and iPad app.
///
/// Values are semantic rather than screen-specific so layout stays coherent
/// as Dynamic Type, split-screen width, and platform chrome change around it.
enum MobileDesign {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum Radius {
        static let compact: CGFloat = 10
        static let card: CGFloat = 16
        static let composer: CGFloat = 24
    }

    enum Metrics {
        static let minimumTouchTarget: CGFloat = 44
        static let readableContentWidth: CGFloat = 720
    }

    static let subtleStroke = Color.primary.opacity(0.08)
    static let elevatedShadow = Color.black.opacity(0.08)
}

extension View {
    /// Keeps wide iPad layouts readable while remaining edge-to-edge on iPhone.
    func mobileReadableWidth() -> some View {
        frame(maxWidth: MobileDesign.Metrics.readableContentWidth)
            .frame(maxWidth: .infinity)
    }

    /// Floating chrome uses native Liquid Glass on iOS 26. Earlier releases
    /// keep the same hierarchy with a system material and semantic separator.
    @ViewBuilder
    func mobileFloatingSurface(
        cornerRadius: CGFloat = MobileDesign.Radius.card,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MobileDesign.subtleStroke, lineWidth: 0.5)
            }
            .shadow(color: MobileDesign.elevatedShadow, radius: 12, y: 5)
        }
    }
}

/// The shared input silhouette used by home chat and source chat.
struct MobileComposerSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, MobileDesign.Spacing.medium)
            .padding(.vertical, MobileDesign.Spacing.xSmall)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(
                    cornerRadius: MobileDesign.Radius.composer,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MobileDesign.Radius.composer,
                    style: .continuous
                )
                .stroke(MobileDesign.subtleStroke, lineWidth: 0.5)
            }
    }
}

/// Consistent circular icon treatment with a full 44-point hit target.
struct MobileCircularActionLabel: View {
    let systemImage: String
    var isProminent = false
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(isProminent ? Color.white : tint)
            .frame(
                width: MobileDesign.Metrics.minimumTouchTarget,
                height: MobileDesign.Metrics.minimumTouchTarget
            )
            .background(isProminent ? tint : tint.opacity(0.10), in: Circle())
            .contentShape(Circle())
    }
}
