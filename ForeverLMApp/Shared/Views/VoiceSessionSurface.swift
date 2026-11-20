import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The voice conversation's screen: the ForeverLM mark moving with the session,
// what the conversation reads, and the controls to mute or end it. Drawn by
// voice mode on the Mac and the iPhone (`RealtimeVoiceController`, OpenAI
// Realtime): a source, the assistant and CarPlay, and
// Review by Voice. It shows no words while the conversation talks (product
// owner). The mark itself (`VoiceOrb`) is also the loading
// indicator on both platforms.

enum VoiceSessionPhase: Equatable {
    case idle
    case connecting
    case live
    case ending
    case failed
}

/// A visual vocabulary for voice activity. The controller owns the status
/// strings, while the surface turns those strings into motion so a learner
/// can read the conversation without UI copy.
enum VoiceOrbActivity: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case muted
    case ending
    case failed
}

struct VoiceContextItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let sourceType: String
    var thumbnailURL: URL? = nil

    var systemImage: String {
        switch sourceType.lowercased() {
        case "paper": return "doc.text.magnifyingglass"
        case "podcast": return "headphones"
        case "book": return "book.closed"
        case "course": return "graduationcap"
        case "meeting": return "person.2.wave.2"
        case "video": return "play.rectangle"
        case "xpost", "x_post": return "bubble.left"
        case "manual": return "link"
        default: return "doc.richtext"
        }
    }

    var tint: Color {
        switch sourceType.lowercased() {
        case "paper": return .purple
        case "podcast": return .orange
        case "book": return .green
        case "course": return .indigo
        case "meeting": return .teal
        case "video": return .red
        case "xpost", "x_post": return .primary
        case "manual": return .secondary
        default: return .blue
        }
    }
}

/// Publishes only the microphone level. Metering ticks arrive many times a
/// second while the microphone is open; routing them through the voice
/// controller's own `objectWillChange` would re-render every observer of the
/// controller on every tick. Views that need the live level observe this
/// object in a leaf (`VoiceLevelOrb`) instead.
@MainActor
final class VoiceMicrophoneLevel: ObservableObject {
    @Published private(set) var value: Float

    init(initial: Float = 0) {
        value = initial
    }

    func set(_ newValue: Float) {
        guard value != newValue else { return }
        value = newValue
    }
}

/// Confines per-tick re-renders to the orb itself.
struct VoiceLevelOrb: View {
    let activity: VoiceOrbActivity
    @ObservedObject var level: VoiceMicrophoneLevel

    var body: some View {
        VoiceOrb(activity: activity, inputLevel: level.value)
    }
}

struct VoiceSessionPresentationState {
    let phase: VoiceSessionPhase
    let statusText: String
    let headerTitle: String
    let headerSystemImage: String
    let contextItems: [VoiceContextItem]
    let isMicrophoneMuted: Bool
    let microphoneLevel: VoiceMicrophoneLevel
    let terminalErrorMessage: String?
    let inlineErrorMessage: String?
    /// The controller's own account of whether the tutor owes a reply: a
    /// learner turn sent and its answer not yet spoken. `statusText` alone
    /// cannot say while it still reads "Listening" from the turn before.
    var isTutorWorking: Bool = false

    private var trimmedStatus: String {
        statusText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Listening" or nothing at all: the status a controller reports when it
    /// has not written anything more specific.
    private var statusIsIdleListening: Bool {
        trimmedStatus.isEmpty || trimmedStatus == "Listening"
    }

    private var isConversing: Bool { phase == .live || phase == .connecting }

    var displayedStatus: String {
        if isConversing, isTutorWorking, statusIsIdleListening {
            return "Thinking"
        }
        if isMicrophoneMuted, statusIsIdleListening {
            return "Microphone Off"
        }
        let status = trimmedStatus
        if !status.isEmpty { return status }
        switch phase {
        case .idle: return "Ready"
        case .connecting: return "Getting ready…"
        case .live: return "Listening"
        case .ending: return "Ending…"
        case .failed: return "Couldn’t start"
        }
    }

    var voiceActivity: VoiceOrbActivity {
        if phase == .failed { return .failed }
        if phase == .ending { return .ending }
        if isMicrophoneMuted { return .muted }

        switch trimmedStatus {
        case "Thinking": return .thinking
        case "Speaking": return .speaking
        default:
            // "Reading your sources…", or a stale "Listening" while a reply
            // is owed: the tutor is at work, and the mark says so whatever
            // the label reads.
            if isConversing, isTutorWorking { return .thinking }
            switch phase {
            case .idle: return .idle
            case .connecting: return .connecting
            case .live: return .listening
            case .ending: return .ending
            case .failed: return .failed
            }
        }
    }
}

/// The voice conversation's presentation. The controller's state is adapted
/// into the value above before it reaches this view.
struct VoiceSessionSurface: View {
    let state: VoiceSessionPresentationState
    let identifierPrefix: String
    let recoveryActionTitle: String?
    let onRecovery: (() -> Void)?
    let onToggleMute: (() -> Void)?
    let onEnd: () -> Void
    let onDismissError: (() -> Void)?
    /// Drawn just above the controls while the conversation is not failed:
    /// the typing field on the iPhone.
    let accessory: AnyView?

    init(
        state: VoiceSessionPresentationState,
        identifierPrefix: String,
        recoveryActionTitle: String? = nil,
        onRecovery: (() -> Void)? = nil,
        onToggleMute: (() -> Void)? = nil,
        onEnd: @escaping () -> Void,
        onDismissError: (() -> Void)? = nil,
        accessory: AnyView? = nil
    ) {
        self.state = state
        self.identifierPrefix = identifierPrefix
        self.recoveryActionTitle = recoveryActionTitle
        self.onRecovery = onRecovery
        self.onToggleMute = onToggleMute
        self.onEnd = onEnd
        self.onDismissError = onDismissError
        self.accessory = accessory
    }

    var body: some View {
        GeometryReader { proxy in
            // The mark is a wide shape, so it takes more of the width than
            // the sphere did and gives most of the height back.
            let orbWidth = min(340, max(240, proxy.size.width * 0.78))

            ZStack {
                background

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 20)

                    if state.phase == .failed {
                        failureState
                    } else {
                        VoiceLevelOrb(
                            activity: state.voiceActivity,
                            level: state.microphoneLevel
                        )
                        .frame(width: orbWidth, height: orbWidth / VoiceOrb.aspectRatio)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Voice status")
                        .accessibilityValue(state.displayedStatus)
                        .accessibilityIdentifier("\(identifierPrefix).status")

                        if !state.contextItems.isEmpty {
                            VoiceContextSources(
                                items: state.contextItems,
                                identifierPrefix: identifierPrefix
                            )
                            .padding(.top, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if let message = state.inlineErrorMessage {
                            inlineError(message)
                                .padding(.top, 14)
                        }
                    }

                    Spacer(minLength: 20)
                }
            }
        }
        // Session content can grow (Dynamic Type, context sources, or an inline
        // error), but the escape hatch must never move or be covered. A
        // safe-area inset keeps the controls in their own topmost interaction
        // region instead of making them compete for space in the content stack.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 14) {
                if let accessory, state.phase != .failed {
                    accessory
                }
                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .zIndex(1)
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: state.contextItems.map(\.id))
    }

    private var background: some View {
        ZStack {
#if os(macOS)
            Color(nsColor: .windowBackgroundColor)
#else
            Color(uiColor: .systemBackground)
#endif
            RadialGradient(
                colors: [Color.accentColor.opacity(0.15), Color.clear],
                center: .center,
                startRadius: 24,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label(state.headerTitle, systemImage: state.headerSystemImage)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var controls: some View {
        if state.phase == .failed, recoveryActionTitle == nil {
            Button("Close", action: onEnd)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("\(identifierPrefix).end")
        } else {
            HStack(spacing: 18) {
                if state.phase == .failed,
                   let recoveryActionTitle,
                   let onRecovery {
                    Button(recoveryActionTitle, action: onRecovery)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("\(identifierPrefix).resume")
                } else if let onToggleMute {
                    Button(action: onToggleMute) {
                        Image(systemName: state.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(state.isMicrophoneMuted ? Color.white : Color.primary)
                            .frame(width: 54, height: 54)
                            .background(
                                state.isMicrophoneMuted ? Color.accentColor : Color.primary.opacity(0.08),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
                    .accessibilityIdentifier("\(identifierPrefix).mute")
                }

                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.red, in: Circle())
                        .shadow(color: Color.red.opacity(0.24), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.phase == .failed ? "Close voice error" : "End voice session")
                .accessibilityIdentifier("\(identifierPrefix).end")
                .accessibilitySortPriority(100)
            }
        }
    }

    private var failureState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.primary.opacity(0.06), in: Circle())

            Text(state.displayedStatus)
                .font(.title3.weight(.semibold))
                .accessibilityLabel("Voice status")
                .accessibilityValue(state.displayedStatus)
                .accessibilityIdentifier("\(identifierPrefix).status")

            if let message = state.terminalErrorMessage ?? state.inlineErrorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
    }

    private func inlineError(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.footnote)
                .lineLimit(2)
                // Named so a test can assert this is *absent* during a healthy
                // session: the banner's whole failure mode is appearing when
                // nothing is wrong, and an assertion about something with no
                // identifier passes whether or not it is on screen. It sits on
                // the message rather than the row so the dismiss button stays
                // its own element for VoiceOver.
                .accessibilityIdentifier("\(identifierPrefix).inlineError")
            if let onDismissError {
                Button(action: onDismissError) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss voice error")
            }
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.1), in: Capsule())
        .padding(.horizontal, 24)
    }
}

struct VoiceContextSources: View {
    let items: [VoiceContextItem]
    let identifierPrefix: String

    var body: some View {
        VStack(spacing: 8) {
            Label("In context", systemImage: "text.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VoiceContextCard(item: item)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("In context: \(item.title)")
                        .accessibilityIdentifier("\(identifierPrefix).contextSource.\(item.id)")
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) \(items.count == 1 ? "source" : "sources") in context")
        .accessibilityIdentifier("\(identifierPrefix).contextSources")
    }
}

private struct VoiceContextCard: View {
    let item: VoiceContextItem

#if os(iOS)
    @State private var paperThumbnail: UIImage? = nil
#endif

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
#if os(iOS)
        .task(id: item.id) {
            await loadPaperThumbnailIfNeeded()
        }
#endif
    }

    @ViewBuilder
    private var thumbnail: some View {
#if os(iOS)
        if let paperThumbnail {
            Image(uiImage: paperThumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            remoteThumbnail
        }
#else
        remoteThumbnail
#endif
    }

    private var remoteThumbnail: some View {
        Group {
            if let thumbnailURL = item.thumbnailURL {
                CachedAsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        thumbnailFallback
                    default:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    }
                }
            } else {
                thumbnailFallback
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnailFallback: some View {
        Image(systemName: item.systemImage)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(item.tint)
            .frame(width: 48, height: 48)
            .background(item.tint.opacity(0.10))
    }

#if os(iOS)
    private func loadPaperThumbnailIfNeeded() async {
        guard item.sourceType.lowercased() == "paper" else { return }
        paperThumbnail = await MobileSourceArtworkLoader.paperThumbnail(sourceID: item.id)
    }
#endif
}

/// The voice orb: the ForeverLM mark, alive and moving with the session.
///
/// It is the logo — the same
/// iridescent infinity ribbon the app icon, the sign-in gate and the loading
/// indicator draw.
///
/// Two brand rules shape everything below, and between them they rule out the
/// two obvious ways to build this.
///
/// **The silhouette is the artwork.** Every pixel you can see is
/// `ForeverLMMarkArtwork` — the shape, the ribbon's twist, its specular edges.
/// A lemniscate is computed and stroked here (`RibbonGeometry`), but only ever
/// into a *mask*: it says which part of the artwork to reveal, and none of it is
/// ever drawn. Nothing on screen is a curve this file decided the shape of.
///
/// **The colours are the artwork's too.** A per-activity palette washed over the
/// mark — blue while listening, red while speaking — would read as a blue
/// infinity symbol, not as our logo, which is exactly the trap `ForeverLMMark`
/// warns about. So there is no palette: the drift here is the same trick that
/// view uses, taking its colour
/// from enlarged, blurred, slowly orbiting copies of the artwork's own pixels,
/// so every colour on screen is one the mark already contains, just somewhere
/// else on it.
///
/// What carries the activity, then, is energy rather than hue — how fast the
/// iridescence wanders, how quickly the pulse laps the loop, how far the glow
/// stands off the ribbon. Two states still need to say something the logo's own
/// colours cannot, and both borrow the loading indicator's vocabulary rather
/// than inventing one: muted drains to silver, and failed drains and glows red
/// under an exclamation mark.
///
/// The orb's box is wider than it is tall: a square box would letterbox the
/// ribbon into a third of the space, so `aspectRatio` is the shape to size it by.
struct VoiceOrb: View {
    /// Width-to-height of the orb's box. Wider than the artwork's own 2.07:1
    /// would give, because the box carries halo headroom above and below the
    /// ribbon.
    static let aspectRatio: CGFloat = 1.75

    let activity: VoiceOrbActivity
    var inputLevel: Float = 0
    /// Multiplier on the clock the motion is derived from: 2 runs every part of
    /// the animation — the goo's lap, the breath, the drift — twice as fast.
    /// The loading indicator passes the user's chosen pace here; voice keeps
    /// its own energy per activity and leaves this at 1.
    var timeScale: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
            VoiceOrbArtwork(
                activity: activity,
                inputLevel: visibleInputLevel,
                time: animates ? timeline.date.timeIntervalSinceReferenceDate * timeScale : 0,
                animates: animates
            )
        }
    }

    private var animates: Bool {
        guard !reduceMotion else { return false }
        switch activity {
        case .connecting, .listening, .thinking, .speaking: return true
        case .idle, .muted, .ending, .failed: return false
        }
    }

    private var visibleInputLevel: CGFloat {
        guard activity == .listening else { return 0 }
        return min(1, CGFloat(sqrt(max(inputLevel, 0))) * 2.4)
    }
}

private struct VoiceOrbArtwork: View {
    let activity: VoiceOrbActivity
    let inputLevel: CGFloat
    let time: TimeInterval
    /// False for a resting activity and for Reduce Motion. The drift is a
    /// blurred composite, so a *stopped* drift is not the shipped artwork — it
    /// is a softer, hazier version of it. At rest the mark is drawn plain, with
    /// one exception: connecting still has something to say, so it keeps the
    /// pipe and fades the colour in and out of it instead.
    let animates: Bool

    var body: some View {
        GeometryReader { proxy in
            // Fit to whichever dimension binds, so a caller that still hands us
            // a square box gets the whole ribbon rather than a cropped one.
            let markWidth = min(
                proxy.size.width * 0.92,
                proxy.size.height * 0.92 * ForeverLMMarkArtwork.aspectRatio
            )
            let markHeight = markWidth / ForeverLMMarkArtwork.aspectRatio
            let style = VoiceOrbStyle(activity: activity)
            let motion = VoiceOrbMotion(
                activity: activity,
                inputLevel: inputLevel,
                time: time,
                animates: animates
            )

            ZStack {
                // Behind the mark, and outside the drain: the whole point of a
                // tint is to say what the drained mark cannot, and a coloured
                // wash laid over the ribbon hides it instead of ringing it.
                if let tint = style.haloTint {
                    tintedHalo(
                        tint: tint,
                        opacity: style.haloOpacity,
                        motion: motion,
                        width: markWidth,
                        height: markHeight
                    )
                }

                ZStack {
                    halo(style: style, motion: motion, width: markWidth, height: markHeight)

                    litMark(style: style, motion: motion, width: markWidth, height: markHeight)
                        .scaleEffect(x: motion.scaleX, y: motion.scaleY)
                }
                .grayscale(style.drain)

                if let icon = style.icon {
                    // The glyph sits on the crossover, the one part of the mark
                    // that is solid ribbon whichever way the colour is running.
                    Image(systemName: icon)
                        .font(.system(size: markHeight * 0.30, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: markHeight * 0.055)
                }
            }
            .frame(width: markWidth, height: markHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Seconds for the resting pipe to fill, and again to empty. Slower than the
    /// goo's lap: a fade with no movement in it has nothing to track, and one
    /// quick enough to feel like a pulse reads as flashing.
    static let restingFillPeriod: Double = 1.6

    /// How much of the drained mark survives as the empty pipe. Low enough to
    /// read as glass, high enough that the loop is still a shape and not a
    /// rumour of one. The white ground is what sets the floor: a pale grey ghost
    /// that is plenty on the dark theme all but vanishes on the light one, and
    /// 0.3 was under that floor.
    static let glassOpacity: Double = 0.42

    /// The artwork at the size everything else in here is drawn to.
    private func mark(width: CGFloat, height: CGFloat) -> some View {
        ForeverLMMarkArtwork().frame(width: width, height: height)
    }

    /// The mark, with its own colour wandering inside it and a light running
    /// the loop.
    private func litMark(
        style: VoiceOrbStyle,
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            if motion.flows {
                flowingMark(motion: motion, width: width, height: height)
            } else if motion.pipeRests {
                restingPipe(motion: motion, width: width, height: height)
            } else if motion.drifts {
                ZStack {
                    // The artwork at full strength under the drift. Without it
                    // the moving states came out visibly paler than the resting
                    // one — blurring something this high-key averages toward
                    // white, and no amount of re-saturating a haze gets the
                    // original's contrast back. Laying the drift over the real
                    // colour keeps the two readings of the mark the same.
                    mark(width: width, height: height)

                    driftField(motion: motion, width: width, height: height)
                        .opacity(0.68)
                }
                // Re-saturating belongs on the field and not on the enclosing
                // ZStack: a filter on the group is enough to stop `.luminosity`
                // below from finding a backdrop, and the mark then simply
                // paints over the colour instead of tinting it.
                //
                // Lower than `ForeverLMMark.drifting`'s 1.35 on purpose, and
                // the difference is the full-strength mark added under the
                // drift above. That view re-saturates two blurred layers and
                // nothing else, so 1.35 lands it back on the artwork's own
                // numbers. Here the same 1.35 was also being applied to colour
                // that had never been washed out, and it pushed the composite
                // past the palette: measured against the asset, it turned about
                // a third of a percent of the ribbon into saturated red and
                // orange — hues the logo does not contain, showing up as
                // stains that wandered the loop as the drift orbited. 1.12
                // holds the composite at the artwork's own saturation.
                .saturation(1.12)

                // Form, twist and specular edges, unmoved, over the drift.
                mark(width: width, height: height)
                    .blendMode(.luminosity)
            } else {
                mark(width: width, height: height)
            }

            if motion.pulseStrength > 0 {
                // Above the artwork and adding light, not below it: a white blob
                // in the backdrop would hand `.luminosity` a colourless hue and
                // bleach the ribbon instead of lighting it.
                pulses(style: style, motion: motion, width: width, height: height)
                    .blendMode(.plusLighter)
            }
        }
        .compositingGroup()
        .mask { mark(width: width, height: height) }
    }

    /// Connecting: the mark as an empty glass pipe with colour running through
    /// it. The one state where the logo is not shown in full — it is being
    /// filled, and an empty tube is the honest picture of a session that has not
    /// come up yet.
    ///
    /// Three passes, all of them the same artwork: the pipe is the mark drained
    /// and turned down to glass, the liquid is the mark at full colour revealed
    /// only where the slug is, and the glow is the liquid again, blurred so it
    /// carries past the pipe wall and travels with it. Nothing is drawn but the
    /// mark; the slug only decides how much of it you can see.
    private func flowingMark(
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            mark(width: width, height: height)
                .grayscale(1)
                .opacity(Self.glassOpacity)

            flowPass(motion: motion, width: width, height: height, behind: true)
            flowPass(motion: motion, width: width, height: height, behind: false)
        }
    }

    /// Connecting with Reduce Motion on: the same empty pipe, with one
    /// localized slug coming and going in place instead of running round it.
    ///
    /// Reduce Motion asks for less movement, not less information, and going
    /// simply still here would have been the second thing — a connecting session
    /// would look exactly like an idle one, and the wait would say nothing at
    /// all. So the goo stops travelling and its one slug fills and empties in
    /// place.
    /// That is the same substitution `ForeverLMLoadingIndicator` makes when it
    /// cannot send its sheen across the mark: same language, no movement in it.
    ///
    private func restingPipe(
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            mark(width: width, height: height)
                .grayscale(1)
                .opacity(Self.glassOpacity)

            ZStack {
                flowPass(motion: motion, width: width, height: height, behind: true)
                flowPass(motion: motion, width: width, height: height, behind: false)
            }
                .modifier(BreathingFill(period: Self.restingFillPeriod))
        }
    }

    /// The half of the slug on one side of the weave: the light it throws, then
    /// the liquid itself, and finally the crossing cut out of both.
    ///
    /// The cut comes last, *after* the blur, because the glow is what was
    /// putting colour on the wrong strand. Cutting the slug and then blurring it
    /// spreads the light straight back over the cut — and since the whole orb is
    /// masked by the artwork, that light has nowhere to go but onto the other
    /// strand, which is the one place it must not be.
    private func flowPass(
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat,
        behind: Bool
    ) -> some View {
        let segments = motion.flowSegments.filter { $0.behind == behind }
        return ZStack {
            mark(width: width, height: height)
                .saturation(1.9)
                .mask { blobs(segments, width: width, height: height, spread: 1.3) }
                .blur(radius: height * 0.16)
                .opacity(0.85)

            mark(width: width, height: height)
                .saturation(1.3)
                .mask { blobs(segments, width: width, height: height, spread: 1) }
        }
        .mask { passRegion(behind: behind, width: width, height: height) }
    }

    /// The slug of liquid: a train of soft blobs strung back along the loop from
    /// the head, fading out at the tail so it reads as something moving through
    /// the pipe rather than a bubble sitting in it.
    ///
    /// The blobs are wider than the ribbon on purpose. A mask narrower than the
    /// tube fills its middle and leaves the walls clear, which reads as a stripe
    /// painted on the pipe instead of as the pipe being full.
    private func blobs(
        _ segments: [VoiceOrbMotion.FlowSegment],
        width: CGFloat,
        height: CGFloat,
        spread: CGFloat
    ) -> some View {
        ZStack {
            ForEach(segments) { segment in
                let diameter = height * 0.52 * spread * CGFloat(0.55 + 0.45 * segment.fade)
                Circle()
                    .fill(Color.white.opacity(pow(segment.fade, 1.3)))
                    .frame(width: diameter, height: diameter)
                    .offset(x: segment.point.x * width, y: segment.point.y * height)
                    .blur(radius: height * 0.08)
            }
        }
    }

    /// Where a slug on one side of the weave is allowed to show.
    ///
    /// The mark is a woven ribbon, and this is what keeps the goo honest about
    /// that. Only the crossing is ever in question: the near pass may not light
    /// the far strand's arms beside it, and the far pass may not light the near
    /// strand lying over it. Everywhere else — the lobes, and above all the lobe
    /// tips, where the two halves of the lap meet — both passes may show. An
    /// earlier version gave each pass only its own half of the lap, and the tips
    /// showed a hard seam wherever the slug's soft edge ran over the join.
    ///
    /// Drawn a good margin larger than the mark's box. A mask is centred on what
    /// it masks, so the extra costs nothing — and without it the blur below
    /// rasterises to the box and shaves the outermost edge of the loops, which
    /// showed up as a rim of unfilled glass around the outside of each lobe.
    private func passRegion(behind: Bool, width: CGFloat, height: CGFloat) -> some View {
        WeavePassRegion(behind: behind, box: CGSize(width: width, height: height))
            .fill(Color.white)
            .frame(width: width + height * 0.3, height: height * 1.3)
            // One tube passing in front of another is a hard edge; this is only
            // enough to keep it from stair-stepping.
            .blur(radius: height * 0.008)
    }

    /// Two enlarged, blurred, slowly orbiting copies of the artwork, which is
    /// where all of the drifting colour comes from.
    private func driftField(
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            driftLayer(phase: motion.drift, scale: 1.22, rate: 1.0, offset: 0,
                       blur: 0.10, travel: 0.075, width: width, height: height)
            driftLayer(phase: motion.drift, scale: 1.48, rate: -0.62, offset: 2.4,
                       blur: 0.13, travel: 0.10, width: width, height: height)
                .opacity(0.5)
        }
    }

    /// One orbiting copy. The two rates are deliberately not a simple ratio, so
    /// the pair does not visibly return to the same arrangement on a short
    /// cycle.
    private func driftLayer(
        phase: Double,
        scale: CGFloat,
        rate: Double,
        offset: Double,
        blur: CGFloat,
        travel: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let angle = phase * rate + offset
        return mark(width: width, height: height)
            .scaleEffect(scale)
            .offset(x: cos(angle) * width * travel,
                    y: sin(angle * 1.27) * height * travel * 1.8)
            .rotationEffect(.degrees(sin(angle * 0.55) * 6))
            .blur(radius: height * blur)
    }

    /// A hot spot of light running the loop, with a dimmer one trailing it.
    private func pulses(
        style: VoiceOrbStyle,
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            pulse(
                opacity: style.pulseOpacity * motion.pulseStrength,
                diameter: height * 0.62,
                x: motion.pulseX * width,
                y: motion.pulseY * height,
                blur: height * 0.22
            )
            pulse(
                opacity: style.pulseOpacity * motion.pulseStrength * 0.45,
                diameter: height * 0.50,
                x: motion.trailX * width,
                y: motion.trailY * height,
                blur: height * 0.20
            )
        }
    }

    private func pulse(
        opacity: Double,
        diameter: CGFloat,
        x: CGFloat,
        y: CGFloat,
        blur: CGFloat
    ) -> some View {
        Circle()
            .fill(Color.white.opacity(opacity))
            .frame(width: diameter, height: diameter)
            .offset(x: x, y: y)
            .blur(radius: blur)
    }

    /// The glow around the ribbon — the mark's own colours, blurred out past its
    /// edge. It replaces the ring the sphere had, which had nothing to sit on
    /// once the shape stopped being a circle.
    private func halo(
        style: VoiceOrbStyle,
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        mark(width: width, height: height)
            // A blur of something this high-key averages to near-white, which
            // would read as a smudge rather than an aura.
            .saturation(1.9)
            .blur(radius: height * 0.22)
            .scaleEffect(motion.haloScale)
            .opacity(style.haloOpacity)
    }

    /// The failure glow: the mark's silhouette filled with one flat colour. The
    /// logo has no red in it, and a failed session has to be readable as failed.
    private func tintedHalo(
        tint: Color,
        opacity: Double,
        motion: VoiceOrbMotion,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Rectangle()
            .fill(tint)
            .frame(width: width, height: height)
            .mask { mark(width: width, height: height) }
            .blur(radius: height * 0.24)
            .scaleEffect(motion.haloScale)
            .opacity(opacity)
    }
}

/// How far each activity moves the mark away from the shipped artwork. Every
/// value here is a quantity of light or a loss of colour — never a new one.
/// Colour coming and going in place, for when Reduce Motion rules out moving
/// anything.
///
/// Driven by an implicit animation rather than by the clock, because the orb
/// pauses its `TimelineView` when motion is off — there is no frame ticking here
/// to read a phase from.
private struct BreathingFill: ViewModifier {
    let period: Double
    @State private var filled = false

    func body(content: Content) -> some View {
        content
            // Not all the way to nothing: a trace of colour left in the loop
            // keeps the two ends of the fade reading as the same object.
            .opacity(filled ? 1 : 0.08)
            .animation(
                .easeInOut(duration: period).repeatForever(autoreverses: true),
                value: filled
            )
            .onAppear { filled = true }
    }
}

/// The ribbon's centre line, fitted to the shipped artwork.
///
/// A lemniscate — and these five numbers are what make it *this* mark's
/// lemniscate rather than a generic one. They come from a search for the stroke
/// that best covers the artwork's own alpha, and they land at an intersection
/// over union of 0.79, about the ceiling for a constant-width stroke over a
/// ribbon whose width varies with its twist.
///
/// Fitting this was not tidiness. The hand-picked curve it replaced was nearly a
/// fifth short in the vertical, so everything positioned along it — the goo, the
/// pulse — tracked inside the loops rather than down the middle of them. It is
/// a guide to where the goo travels, not to where the ribbon's edges are: the
/// weave comes from `RibbonCrossing`.
private enum RibbonGeometry {
    /// Offset of the crossing from the centre of the box, in box fractions.
    static let centreX: CGFloat = 0.0078
    static let centreY: CGFloat = 0.0020
    static let amplitudeX: CGFloat = 0.4327
    static let amplitudeY: CGFloat = 1.0176
    /// A point on the centre line, as a fraction of the box measured from its
    /// centre. `t` runs a lap over `2 * pi`, passing through the crossing at
    /// `pi / 2` and again at `3 * pi / 2`.
    static func point(at t: Double) -> CGPoint {
        let s = sin(t)
        let c = cos(t)
        let d = 1 + s * s
        return CGPoint(x: centreX + amplitudeX * CGFloat(c / d),
                       y: centreY + amplitudeY * CGFloat(s * c / d))
    }
}

/// The crossing, measured off the artwork rather than fitted.
///
/// The centre line above is a good guide to where the ribbon runs and a bad one
/// to where its edges are at the crossing. The ribbon's width was fitted with
/// the crossing left out — a march out from the centre line there runs straight
/// into the other strand — so the fit was free to do anything across it, and
/// it did: the near strand came out a quarter too narrow and a third of its
/// width off to the lower right. The far pass's goo then showed through the
/// upper edge of the strand lying over it, as a bright band across the knot.
///
/// So the weave is taken from the one place the artwork states it outright.
/// Around the crossing the two strands leave four gaps, and the corner of each
/// gap nearest the crossing is where an edge of one strand meets an edge of the
/// other. The near strand's edges run left–top and bottom–right, the far
/// strand's top–right and left–bottom, and near the crossing both strands are
/// straight enough that those lines are their edges.
///
/// Each point is the innermost transparent pixel of its gap in the 1024 × 495
/// asset, as a fraction of the box measured from its centre.
private enum RibbonCrossing {
    static let left = CGPoint(x: -0.0430, y: 0.0859)
    static let top = CGPoint(x: 0.0391, y: -0.0778)
    static let right = CGPoint(x: 0.1064, y: 0.0717)
    static let bottom = CGPoint(x: 0.0283, y: 0.2394)

    /// How far from the crossing the straight bands are trusted, in heights.
    /// Out to here each band lies on its own strand and the lobe holes; much
    /// further and the strands have curved away from the lines.
    static let reach: CGFloat = 0.65

    /// How far a band's edges sit outside the lines through the gaps, in
    /// heights: the upper edge first, then the lower.
    ///
    /// The near strand's own edges get only enough to cover their antialiasing.
    /// The far band is pushed out generously, because its arms start curving
    /// away just past the gaps and it only ever overhangs a lobe hole.
    static let nearGrowth: (upper: CGFloat, lower: CGFloat) = (0.004, 0.004)
    static let farGrowth: (upper: CGFloat, lower: CGFloat) = (0.03, 0.03)

    /// Where the near strand's glass rim ends and its colour starts, as a
    /// growth like the ones above — so negative, inside the gap lines.
    ///
    /// The rim is clear, and across the crossing what you see through it is the
    /// far strand: 7 px of it along the upper edge and 3 px along the lower,
    /// measured on the 495 px asset as the point where the colour stops being
    /// the far strand's. That strip belongs to the far pass. Given to the near
    /// one, the near goo lit it as a stripe of colour lying on the far strand,
    /// and the far goo stopped short of where the eye sees it pass under.
    static let nearColourGrowth: (upper: CGFloat, lower: CGFloat) = (-0.013, -0.005)
}

/// Where one pass of the goo may show: everywhere, less the strand that hides
/// it at the crossing.
///
/// The cut is a real path operation and not a `destinationOut` blend over the
/// top, which is what the weave started as. The blend renders correctly on
/// screen and is silently ignored inside a `.mask`, so the hole simply was not
/// there when it mattered.
///
/// `box` is the mark's own box. It is passed rather than taken from `rect` so
/// the region can be drawn into a larger rect without the crossing growing with
/// it.
private struct WeavePassRegion: Shape {
    let behind: Bool
    let box: CGSize

    func path(in rect: CGRect) -> Path {
        let pixel = { (unit: CGPoint) in
            CGPoint(x: rect.midX + unit.x * box.width, y: rect.midY + unit.y * box.height)
        }
        let left = pixel(RibbonCrossing.left)
        let top = pixel(RibbonCrossing.top)
        let right = pixel(RibbonCrossing.right)
        let bottom = pixel(RibbonCrossing.bottom)
        let centre = CGPoint(
            x: (left.x + top.x + right.x + bottom.x) / 4,
            y: (left.y + top.y + right.y + bottom.y) / 4
        )
        let reach = RibbonCrossing.reach * box.height
        let nearby = Path(ellipseIn: CGRect(
            x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2
        ))
        let band = { (one: (CGPoint, CGPoint), other: (CGPoint, CGPoint),
                      growth: (upper: CGFloat, lower: CGFloat)) in
            Self.band(one, other, growth: growth, scale: box.height, reach: reach)
        }
        let near = band((left, top), (bottom, right), RibbonCrossing.nearGrowth)
        let far = band((top, right), (left, bottom), (0, 0))
        // The near strand's glass rim, only where the far strand is behind it.
        // Past the gaps the rim has nothing behind it and stays the near
        // strand's.
        let rim = far.intersection(near).subtracting(
            band((left, top), (bottom, right), RibbonCrossing.nearColourGrowth)
        )
        let hidden: Path
        if behind {
            // Under the crossing: the near strand lies over the far pass.
            hidden = near.subtracting(rim).intersection(nearby)
        } else {
            // Over the crossing: the far strand's arms beside it and what shows
            // of it through the rim, but not the stretch the near strand
            // covers, which is where this pass is.
            let farArms = band((top, right), (left, bottom), RibbonCrossing.farGrowth)
            hidden = farArms.subtracting(near).union(rim).intersection(nearby)
        }
        return Path(rect).subtracting(hidden)
    }

    /// The strip between two edges, each given as a pair of points taken in the
    /// same direction along the strand, run out past both ends and each pushed
    /// outwards by its own `growth`, in multiples of `scale`.
    private static func band(
        _ one: (CGPoint, CGPoint),
        _ other: (CGPoint, CGPoint),
        growth: (upper: CGFloat, lower: CGFloat),
        scale: CGFloat,
        reach: CGFloat
    ) -> Path {
        let middle = CGPoint(
            x: (one.0.x + one.1.x + other.0.x + other.1.x) / 4,
            y: (one.0.y + one.1.y + other.0.y + other.1.y) / 4
        )
        func edge(_ from: CGPoint, _ to: CGPoint, growth: CGFloat) -> (CGPoint, CGPoint) {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(sqrt(dx * dx + dy * dy), .leastNormalMagnitude)
            let along = CGVector(dx: dx / length, dy: dy / length)
            var outward = CGVector(dx: -along.dy, dy: along.dx)
            if (from.x - middle.x) * outward.dx + (from.y - middle.y) * outward.dy < 0 {
                outward = CGVector(dx: -outward.dx, dy: -outward.dy)
            }
            let run = reach * 2
            let growth = growth * scale
            return (
                CGPoint(x: from.x - along.dx * run + outward.dx * growth,
                        y: from.y - along.dy * run + outward.dy * growth),
                CGPoint(x: to.x + along.dx * run + outward.dx * growth,
                        y: to.y + along.dy * run + outward.dy * growth)
            )
        }
        let first = edge(one.0, one.1, growth: growth.upper)
        let second = edge(other.0, other.1, growth: growth.lower)
        var path = Path()
        path.move(to: first.0)
        path.addLine(to: first.1)
        path.addLine(to: second.1)
        path.addLine(to: second.0)
        path.closeSubpath()
        return path
    }
}

private struct VoiceOrbStyle {
    /// How far the mark's colour is drained. 0 is the artwork as shipped.
    let drain: Double
    let haloOpacity: Double
    /// A flat colour for the glow, for the one state the logo's own palette
    /// cannot express. `nil` glows in the mark's own colours.
    let haloTint: Color?
    let pulseOpacity: Double
    let icon: String?

    init(activity: VoiceOrbActivity) {
        switch activity {
        case .idle:
            drain = 0
            haloOpacity = 0.34
            haloTint = nil
            pulseOpacity = 0
            // No glyph. Idle is the start screen, where the mark is drawn large
            // and plain and is the only thing on the surface — a flat white
            // `waveform` stamped across the crossover reads as a sticker on the
            // logo, not as part of it, and it is a stock Apple symbol sitting on
            // top of the one piece of shipped brand artwork. Nothing is lost by
            // dropping it: the button underneath already says "Start Voice", and
            // `MobileSignInGate` made the same correction for the same reason.
            icon = nil
        case .connecting:
            drain = 0
            // Both zero because connecting is the pipe: a glow around the whole
            // ribbon would light a tube that is mostly empty, and the slug is
            // already the travelling light a pulse would have been.
            haloOpacity = 0
            haloTint = nil
            pulseOpacity = 0
            icon = nil
        case .listening:
            drain = 0
            haloOpacity = 0.56
            haloTint = nil
            pulseOpacity = 0.22
            icon = nil
        case .thinking:
            drain = 0
            haloOpacity = 0.66
            haloTint = nil
            pulseOpacity = 0.28
            icon = nil
        case .speaking:
            drain = 0
            haloOpacity = 0.74
            haloTint = nil
            pulseOpacity = 0.34
            icon = nil
        case .muted:
            // Draining to silver is the loading indicator's language for "the
            // mark is here but nothing is happening", and it is obvious on a
            // white ground and a dark one alike.
            drain = 0.92
            haloOpacity = 0.18
            haloTint = nil
            pulseOpacity = 0
            icon = "mic.slash.fill"
        case .ending:
            drain = 0.55
            haloOpacity = 0.22
            haloTint = nil
            pulseOpacity = 0
            icon = nil
        case .failed:
            drain = 0.72
            haloOpacity = 0.55
            haloTint = .red
            pulseOpacity = 0
            icon = "exclamationmark"
        }
    }
}

private struct VoiceOrbMotion {
    /// Orbit angle of the colour drift, in radians.
    let drift: Double
    /// False for a resting activity, so the caller draws the plain artwork.
    let drifts: Bool
    /// True while the mark is an empty pipe with goo running through it.
    let flows: Bool
    /// True when the pipe is still the right picture but nothing may travel:
    /// connecting with Reduce Motion on.
    let pipeRests: Bool
    /// The slug of liquid, head first. It travels when `flows` and stays at one
    /// fixed location when `pipeRests`.
    let flowSegments: [FlowSegment]

    /// One blob of the slug.
    struct FlowSegment: Identifiable {
        let id: Int
        /// Position, as fractions of the mark's box.
        let point: CGPoint
        /// 1 at the head, falling to 0 at the tail.
        let fade: Double
        /// True on the pass that goes *under* the crossing. The lemniscate
        /// meets itself twice a lap: the pass through `t = pi/2` runs
        /// lower-right to upper-left, which is the artwork's far strand, and the
        /// one through `3 * pi/2` is the near one. Splitting the whole lap in
        /// half at 0 and pi is enough to separate them — a blob on the wrong
        /// side of that line is out in a lobe, nowhere near the occluder.
        let behind: Bool
    }
    let scaleX: CGFloat
    let scaleY: CGFloat
    let haloScale: CGFloat
    /// 0 at rest, so the pulse is absent rather than parked somewhere on the
    /// ribbon looking like a blemish.
    let pulseStrength: Double
    /// Pulse and trail positions, as fractions of the mark's width and height.
    let pulseX: CGFloat
    let pulseY: CGFloat
    let trailX: CGFloat
    let trailY: CGFloat

    init(
        activity: VoiceOrbActivity,
        inputLevel: CGFloat,
        time: TimeInterval,
        animates: Bool
    ) {
        /// How hard the mark is running, with listening as 1.
        let energy: Double
        let breath: CGFloat
        switch activity {
        case .connecting:
            energy = 0.60
            breath = CGFloat(sin(time * 1.8)) * 0.020
        case .listening:
            energy = 1.00
            breath = CGFloat(sin(time * 2.2)) * 0.014 + inputLevel * 0.060
        case .thinking:
            energy = 1.90
            breath = CGFloat(sin(time * 3.0)) * 0.026
        case .speaking:
            energy = 2.60
            breath = CGFloat(sin(time * 4.8)) * 0.040
        case .idle, .muted, .ending, .failed:
            energy = 0
            breath = 0
        }

        let running = animates && energy > 0
        // Connecting is drawn as the pipe instead of the drift, so it opts out
        // of the treatment every other running state gets.
        flows = running && activity == .connecting
        pipeRests = !animates && activity == .connecting
        drifts = running && !flows

        if flows || pipeRests {
            // A lap every three and a half seconds or so — its own rate rather
            // than the activity's, because this one is meant to be watched while
            // you wait, and the drift's pace would read as stalled.
            let head = flows ? time * 1.7 : 0.65
            flowSegments = (0..<Self.slugSegments).map { index in
                let t = head - Double(index) * Self.slugSpacing
                let point = RibbonGeometry.point(at: t)
                let lap = t.truncatingRemainder(dividingBy: 2 * .pi)
                let wrapped = lap < 0 ? lap + 2 * .pi : lap
                return FlowSegment(
                    id: index,
                    point: CGPoint(x: point.x, y: point.y),
                    fade: 1 - Double(index) / Double(Self.slugSegments),
                    behind: wrapped < .pi
                )
            }
        } else {
            flowSegments = []
        }
        // One lap of the drift every 14 seconds while listening. Long on
        // purpose: the pulse is the part meant to be watched, and colour that
        // wanders fast enough to follow competes with it.
        drift = time * energy * (2 * .pi / 14)

        // The mark breathes rather than squashing. The sphere could get away
        // with pinching one axis against the other; a ribbon this wide reads as
        // a rubber band when you do that.
        scaleX = 1 + breath * 0.75
        scaleY = 1 + breath
        haloScale = 1.04 + max(0, breath) * 1.8 + inputLevel * 0.08

        pulseStrength = running ? 1 : 0
        let travel = time * energy * 0.74
        let head = RibbonGeometry.point(at: travel)
        let tail = RibbonGeometry.point(at: travel - 0.85)
        pulseX = head.x
        pulseY = head.y
        trailX = tail.x
        trailY = tail.y
    }

    /// How many overlapping blobs make up the one liquid slug, and how far
    /// apart they sit. Keep the train short enough that only one localized
    /// piece of pipe is coloured at a time, including while its head passes the
    /// weave. These are samples of one body, never separate bubbles around the
    /// loop.
    private static let slugSegments = 6
    private static let slugSpacing = 0.16
}

#Preview("Voice orb") {
    VStack(spacing: 20) {
        ForEach(
            [
                ("Idle", VoiceOrbActivity.idle),
                ("Listening", .listening),
                ("Thinking", .thinking),
                ("Speaking", .speaking),
                ("Muted", .muted),
                ("Failed", .failed)
            ],
            id: \.0
        ) { name, activity in
            HStack {
                Text(name).font(.caption).frame(width: 80, alignment: .leading)
                VoiceOrb(activity: activity, inputLevel: 0.4)
                    .frame(width: 240, height: 240 / VoiceOrb.aspectRatio)
            }
        }
    }
    .padding(28)
}


/// Asked in place of an error when voice mode starts with no OpenAI key: the
/// key is checked with OpenAI, stored in the iCloud Keychain, and `onSaved`
/// starts the conversation that was asked for.
struct VoiceOwnKeyPrompt: View {
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.primary.opacity(0.06), in: Circle())
            Text("Add your OpenAI key")
                .font(.title3.weight(.semibold))
            Text("Voice mode runs on your own OpenAI API key, and OpenAI bills you for it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("Paste your OpenAI API key", text: $draft)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .onSubmit { Task { await save() } }
                .accessibilityIdentifier("voice.ownKey.field")
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice.ownKey.error")
            }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save and start") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty || saving)
                .accessibilityIdentifier("voice.ownKey.save")
            }
            Link("Get an OpenAI key", destination: ManagedAI.ownOpenAIVoiceKeysURL)
                .font(.caption)
            Label("Kept in your iCloud Keychain and sent only to OpenAI, never to ForeverLM.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() async {
        let key = trimmed
        guard !key.isEmpty, !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            if case .rejected(let reason) = try await ManagedAI.checkOwnOpenAIVoiceKey(key) {
                errorMessage = reason
                return
            }
        } catch {
            errorMessage = "Couldn't check the key with OpenAI: \(error.localizedDescription)"
            return
        }
        await Task.detached(priority: .userInitiated) { ManagedAI.setOwnOpenAIVoiceKey(key) }.value
        draft = ""
        onSaved()
    }
}
