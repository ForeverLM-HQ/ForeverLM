import SwiftUI

/// The ForeverLM mark with its colour in motion — the branded stand-in for a
/// spinner on surfaces that wait long enough to be worth naming.
///
/// The mark is the shipped brand artwork (`ForeverLMMarkArtwork`), not a curve
/// drawn to look like it. An earlier version stroked a Bernoulli lemniscate, and
/// it read as *an* infinity symbol rather than *our* logo: the real mark is a
/// twisted iridescent ribbon whose width, colour and shading vary all the way
/// round, and none of that survives a two-tone stroke of even thickness. Brand
/// rule, from `brand/README.md`: do not invent new marks. So the animation is
/// applied *to* the artwork instead.
///
/// The default sheen moves saturation, not opacity. The resting mark is the same
/// artwork desaturated to silver — still fully opaque, so the logo is legible
/// the whole time — and a band of the untouched iridescent original sweeps
/// through it. Chat opts into the flowing-goo style: the same artwork becomes a
/// hollow glass pipe while a soft iridescent slug runs its woven loop.
/// Fading the mark in and out instead was the first attempt and barely showed:
/// the artwork is pastel, so on a white ground 45% and 100% of it look nearly
/// alike. Draining the colour is the one change to it that is obvious on both
/// grounds.
///
/// This is deliberately not a `ProgressView` replacement everywhere. Reach for
/// it where the wait reads as *the app* thinking — a surface held empty while it
/// starts up, or a chat with a reply on the way. Incidental waits inside a row
/// keep the system spinner: a tool step finishing inside a disclosure is the
/// machine being busy, not the product working, and a mark on every one of them
/// in a long retrieval loop is noise.
struct ForeverLMLoadingIndicator: View {
    enum Style: Equatable {
        /// A soft colour sheen crossing the complete mark.
        case sheen
        /// The mark reads as a translucent pipe with an iridescent slug
        /// travelling through its woven loop.
        case flowingGoo
    }

    /// Width of the mark. Height follows from the artwork's own proportions —
    /// the artwork is about 2:1, so a mark set to the height of a line of body
    /// text is twice as wide as the spinner it stands in for. `inlineWidth` is
    /// the size that lands on that line.
    var width: CGFloat = 44
    var style: Style = .sheen

    /// Sized to the status line it actually sits on, not to body text: the
    /// working indicator sets its label in `.caption`, so a mark scaled to body
    /// height towered over the words next to it and read as a logo the row was
    /// hung from rather than punctuation in front of the text. 26pt wide is
    /// about 13pt tall — a caption line — which is where it belongs.
    static let inlineWidth: CGFloat = 26
    /// Seconds for the sheen to cross the mark once, at a speed of 1.
    var period: Double = 2.1
    /// Pace multiplier. Nil reads the user's setting (Settings → Appearance on
    /// the Mac, Display on the iPhone); a value pins it, for previews and for a
    /// settings control showing the mark at the speed being chosen.
    var speed: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LoadingIndicatorSpeed.key) private var storedSpeed: Double = LoadingIndicatorSpeed.defaultValue

    /// How wide the coloured band is, as a fraction of the mark's width.
    private static let sheenSpan: CGFloat = 0.30

    /// How far the band leans off vertical. The loops run on a diagonal through
    /// the crossing, so a tilted band tracks the ribbon rather than cutting
    /// straight down through both lobes at once.
    private static let sheenTilt: Angle = .degrees(-20)

    /// How far the resting mark is drained. Short of 1 so a trace of the
    /// iridescence survives and the silver does not read as a grey placeholder.
    private static let restingGrayscale: Double = 0.92

    /// The resting mark stays nearly solid — it is the logo, not a ghost of it.
    private static let restingOpacity: Double = 0.85

    private var height: CGFloat { width / ForeverLMMarkArtwork.aspectRatio }

    private var effectiveSpeed: Double { LoadingIndicatorSpeed.clamped(speed ?? storedSpeed) }
    /// The sheen's lap at the effective speed.
    private var effectivePeriod: Double { period / effectiveSpeed }

    var body: some View {
        Group {
            if style == .flowingGoo {
                // Reuse the shared pipe renderer used while Voice connects.
                // It preserves the artwork's actual silhouette and crossing,
                // including which strand passes over the other, instead of
                // approximating the logo with a generic infinity stroke.
                VoiceOrb(activity: .connecting, timeScale: effectiveSpeed)
                    .accessibilityHidden(true)
            } else if reduceMotion {
                // No travel: a still mark would not read as "working", so the
                // colour comes and goes across the whole mark at once instead of
                // moving anything. Same language as the sweep, no motion in it.
                mark
                    .modifier(BreathingColor(period: effectivePeriod, drained: Self.restingGrayscale))
            } else {
                mark
                    .grayscale(Self.restingGrayscale)
                    .opacity(Self.restingOpacity)
                    .overlay {
                        TimelineView(.animation) { context in
                            sheen(phase: phase(at: context.date))
                        }
                    }
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var mark: ForeverLMMarkArtwork { ForeverLMMarkArtwork() }

    /// The coloured pass: the untouched artwork, revealed only inside a soft
    /// band, with a blurred copy underneath for the bloom the render has.
    private func sheen(phase: Double) -> some View {
        mark
            .background {
                mark
                    .blur(radius: height * 0.14)
                    .opacity(0.6)
            }
            .mask { band(phase: phase) }
    }

    /// The travelling band, as a gradient rectangle offset across the mark.
    ///
    /// Offsetting a fixed band beats animating gradient stop locations: stops
    /// have to stay ordered and inside 0...1, so a band leaving the frame there
    /// collapses against the edge into a hard line instead of sliding off.
    private func band(phase: Double) -> some View {
        let bandWidth = width * Self.sheenSpan
        // Travel far enough past both edges that the tilted band clears the
        // corners completely before the lap restarts.
        let travel = width + bandWidth
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: bandWidth, height: height * 2.4)
            .rotationEffect(Self.sheenTilt)
            .offset(x: -travel / 2 + travel * phase)
            .frame(width: width, height: height)
    }

    /// Position of the sheen, taken from the clock rather than an implicit
    /// animation, so the jump back to the start at the end of a lap is a jump
    /// off-frame rather than an eased slide back across the mark.
    private func phase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        let period = effectivePeriod
        return (elapsed.truncatingRemainder(dividingBy: period)) / period
    }
}

/// A slow colour fade in place, for when Reduce Motion rules out travelling
/// anything. Cross-fades are what Reduce Motion asks for in place of movement,
/// and draining to silver keeps the logo itself fully drawn throughout.
private struct BreathingColor: ViewModifier {
    let period: Double
    let drained: Double
    @State private var isDrained = false

    func body(content: Content) -> some View {
        content
            .grayscale(isDrained ? drained : 0)
            .animation(
                .easeInOut(duration: period).repeatForever(autoreverses: true),
                value: isDrained
            )
            .onAppear { isDrained = true }
    }
}

#Preview("Loading indicator") {
    VStack(spacing: 32) {
        ForeverLMLoadingIndicator()
        ForeverLMLoadingIndicator(width: 88, style: .flowingGoo)
        ForeverLMLoadingIndicator(width: 88)
        ForeverLMLoadingIndicator(width: 132, period: 3)
        ForeverLMLoadingIndicator(width: 88, style: .flowingGoo, speed: 2.5)
    }
    .padding(40)
}
