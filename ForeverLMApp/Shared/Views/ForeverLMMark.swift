import SwiftUI

/// The shipped brand artwork, and the only place that names the asset.
///
/// `BrandMark` is `brand/foreverlm-logo-transparent-tight.png` — the loops
/// cropped out of the transparent master, so a caller that sets a width gets the
/// mark and no empty box around it. Both asset catalogs carry a copy.
///
/// Brand rule, from `brand/README.md`: do not invent new marks. Anything that
/// wants to show the logo draws this, rather than approximating it with a path
/// or an SF Symbol.
struct ForeverLMMarkArtwork: View {
    /// Pixel bounds of the asset, so callers can derive a height that matches
    /// the artwork instead of letterboxing or stretching it.
    static let aspectRatio: CGFloat = 1024.0 / 495.0

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
    }
}

/// The mark, optionally with its colour drifting inside it.
///
/// The artwork is a glassy iridescent ribbon, and `.drifting` makes that
/// iridescence wander the way it looks like it should — cyan easing round into
/// the far loop, gold surfacing where violet was. The silhouette, the shading
/// and the specular edges never move, so it reads as light moving through the
/// mark rather than as a different mark.
///
/// How it works: the colour comes from two enlarged, blurred, slowly orbiting
/// copies of the artwork's own pixels, and the untouched artwork is composited
/// over them in `.luminosity` to put the form back. The whole thing is then
/// masked by the artwork's alpha, so nothing escapes the loops. Using the
/// artwork as its own colour field is what keeps the palette honest — every
/// colour on screen is one the mark already contains, just somewhere else on it.
///
/// A hue rotation would have been a line of code and was the wrong answer: it
/// turns the whole mark at once, so the logo goes green, then blue, then pink.
/// Nothing floats.
struct ForeverLMMark: View {
    enum Motion {
        /// The artwork exactly as shipped.
        case still
        /// Colour wandering inside the silhouette.
        case drifting
    }

    /// Width of the mark. Height follows from the artwork's proportions.
    var width: CGFloat
    var motion: Motion = .still
    /// Seconds for the leading colour layer to complete one orbit. Long on
    /// purpose: this is ambient, and anything quick enough to watch is quick
    /// enough to distract from whatever the screen is actually for.
    var driftPeriod: Double = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { width / ForeverLMMarkArtwork.aspectRatio }

    var body: some View {
        Group {
            switch motion {
            case .still:
                ForeverLMMarkArtwork()
            case .drifting:
                if reduceMotion {
                    // Reduce Motion is a request for less movement, and an
                    // ambient flourish is the first thing that should go. There
                    // is nothing to communicate here — this is not a spinner —
                    // so it simply stops.
                    ForeverLMMarkArtwork()
                } else {
                    // 30fps rather than the display's rate: the drift takes 18
                    // seconds to go round, so nothing about it needs 120, and
                    // each frame re-blurs three layers.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        drifting(phase: phase(at: context.date))
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func drifting(phase: Double) -> some View {
        ZStack {
            ZStack {
                colorLayer(phase: phase, scale: 1.22, rate: 1.0, offset: 0,
                           blur: 0.10, travel: 0.075)
                colorLayer(phase: phase, scale: 1.48, rate: -0.62, offset: 2.4,
                           blur: 0.13, travel: 0.10)
                    .opacity(0.5)
            }
            // The blurred layers average toward pastel mush; this pulls the
            // saturation back up to roughly where the artwork sits.
            .saturation(1.35)

            // Form, shading and specular highlights, unmoved.
            ForeverLMMarkArtwork()
                .blendMode(.luminosity)
        }
        .compositingGroup()
        .mask { ForeverLMMarkArtwork() }
    }

    /// One orbiting copy of the artwork. The two rates are deliberately not a
    /// simple ratio, so the pair does not visibly return to the same
    /// arrangement on a short cycle.
    private func colorLayer(
        phase: Double,
        scale: CGFloat,
        rate: Double,
        offset: Double,
        blur: CGFloat,
        travel: CGFloat
    ) -> some View {
        let angle = phase * rate + offset
        return ForeverLMMarkArtwork()
            .scaleEffect(scale)
            .offset(x: cos(angle) * width * travel,
                    y: sin(angle * 1.27) * height * travel * 1.8)
            .rotationEffect(.degrees(sin(angle * 0.55) * 6))
            .blur(radius: height * blur)
    }

    /// Orbit angle, taken from the clock rather than an implicit animation so
    /// the drift is continuous and has no start or end to land on.
    private func phase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return elapsed * 2 * .pi / driftPeriod
    }
}

#Preview("Mark") {
    VStack(spacing: 28) {
        ForeverLMMark(width: 240, motion: .still)
        ForeverLMMark(width: 240, motion: .drifting)
        ForeverLMMark(width: 240, motion: .drifting, driftPeriod: 4)
    }
    .padding(32)
}
