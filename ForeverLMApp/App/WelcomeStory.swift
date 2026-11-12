// The welcome story, its clip player and the recommended badge.
import AppKit
import AVFoundation
import SwiftUI

// MARK: - Welcome story

/// The welcome's opening, drawn to one sentence the learner should be able to
/// say afterwards: "I take in a lot every day, most of it is gone within a
/// week, and ForeverLM keeps all of it within reach."
///
/// What makes that hard to see is that forgetting is invisible: you remember
/// that you read a paper, not what it said. So the stage is one day's
/// timeline, and each thing taken in lands on it as a card. "A week later",
/// every card keeps its kind but its title greys into placeholder bars,
/// oldest first; the book stays a little clearer while "I've seen this idea
/// before, in that book…" is said. The mark then answers it: the same cards
/// come back whole and gather into one stack under it. One page then says
/// how, in three rows: what they write down comes back as quizzes, the AI is
/// theirs to choose, and the data is theirs to keep, in their own iCloud.
/// Data comes last because the first step, Full
/// Disk Access, asks to read some of it. The product owner, 2026-09-24: fewer
/// screens, so the three share one page.
/// The product owner, 2026-09-22: the onboarding starts with the story, not with a
/// settings question; 2026-09-24: the day has to look far better than a grid
/// of icons.
struct WelcomeStory: View {
    /// One thing taken in during the day. The titles are invented: the story
    /// never shows anyone's own library.
    struct Moment: Identifiable {
        let icon: String
        let kind: String
        let title: String
        /// When it happened, in hours from midnight.
        let hours: Double
        let tint: Color
        var id: String { icon }
    }

    static let day: [Moment] = [
        Moment(icon: "headphones", kind: "Podcast", title: "Why sleep clears the brain", hours: 7.25, tint: .purple),
        Moment(icon: "envelope.open", kind: "Newsletter", title: "This week in longevity", hours: 8.75, tint: .orange),
        Moment(icon: "doc.text.magnifyingglass", kind: "Paper", title: "Mitochondria move between cells", hours: 10.25, tint: .blue),
        Moment(icon: "person.3", kind: "Meeting", title: "Lab meeting: next experiments", hours: 12, tint: .green),
        Moment(icon: "newspaper", kind: "Article", title: "The race for solid-state batteries", hours: 14, tint: .teal),
        Moment(icon: "play.rectangle.fill", kind: "Lecture", title: "How memory consolidates", hours: 16.5, tint: .red),
        Moment(icon: "book", kind: "Book", title: "Chapter 7: The forgetting curve", hours: 19.5, tint: .brown),
        Moment(icon: "text.bubble", kind: "Posts on X", title: "43 posts in your feed", hours: 22.5, tint: .indigo),
    ]

    /// The card the quote is about, kept a little clearer than the rest.
    static let halfRememberedIcon = "book"

    enum Beat: Int, Comparable {
        /// Played on a clock.
        case day, question
        /// Turned by the learner.
        case answer, howItWorks
        static func < (lhs: Beat, rhs: Beat) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let yourAIIcon = "slider.horizontal.3"
    static let rememberIcon = "rectangle.stack"
    static let yourDataIcon = "lock.shield"

    var startsAtEnd = false
    var onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat: Beat = .day
    @State private var shownMoments = 0
    /// The day's clock, in hours; the playhead on the timeline follows it.
    @State private var clock: Double = 7
    /// How many cards, oldest first, have lost their titles.
    @State private var forgottenMoments = 0
    @State private var showsFingertips = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch beat {
                case .day, .question, .answer:
                    // One stage for all three, so the cards the day laid down
                    // are the ones that fade and the ones that come back.
                    dayStage
                        .transition(.opacity)
                case .howItWorks:
                    howItWorks
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // One slot at the bottom, so nothing shifts when the button
            // changes from page to page.
            Group {
                switch beat {
                case .day, .question:
                    Button("Skip") { advance(to: .answer) }
                        .buttonStyle(.hoverWash)
                        .foregroundStyle(.secondary)
                case .answer:
                    primaryButton("Continue") { advance(to: .howItWorks) }
                case .howItWorks:
                    primaryButton("Get Started", action: onStart)
                }
            }
            .keyboardShortcut(.defaultAction)
            .frame(height: 44)
            .padding(.bottom, 36)
        }
        .task { await play() }
    }

    // MARK: Day stage

    private static let stageSize = CGSize(width: 700, height: 470)
    private static let cardSize = CGSize(width: 96, height: 118)
    private static let timelineY: CGFloat = 258
    private static let timelineSpan: ClosedRange<CGFloat> = 20...680
    private static let hoursSpan: ClosedRange<Double> = 7...23

    private var dayStage: some View {
        ZStack(alignment: .topLeading) {
            headline
            timeline
            cards
            answerHeadline
            fingertips
        }
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
    }

    /// The day's line and its readout, then the question in the same place.
    private var headline: some View {
        ZStack {
            Text("Every day, you take in so much.")
                .opacity(beat == .day && shownMoments > 0 ? 1 : 0)
            Text("How much of it do you actually remember?")
                .opacity(beat == .question ? 1 : 0)
        }
        .font(.system(size: 26, weight: .semibold, design: .rounded))
        .multilineTextAlignment(.center)
        .position(x: Self.stageSize.width / 2, y: 22)
    }

    private var timeline: some View {
        let start = Self.timelineSpan.lowerBound
        let playhead = x(forHours: clock)
        let isDay = beat == .day
        return ZStack(alignment: .topLeading) {
            Text(isDay ? Self.clockText(clock) : "A week later")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .position(x: Self.stageSize.width / 2, y: 60)

            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: Self.timelineSpan.upperBound - start, height: 3)
                .position(x: (start + Self.timelineSpan.upperBound) / 2, y: Self.timelineY)
            Capsule()
                .fill(Color.accentColor.opacity(isDay ? 1 : 0.25))
                .frame(width: max(playhead - start, 0), height: 3)
                .position(x: (start + playhead) / 2, y: Self.timelineY)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 11, height: 11)
                .shadow(color: .accentColor.opacity(0.6), radius: 6)
                .opacity(isDay && shownMoments > 0 ? 1 : 0)
                .position(x: playhead, y: Self.timelineY)

            ForEach(Array(Self.day.enumerated()), id: \.element.id) { index, moment in
                let above = index.isMultiple(of: 2)
                let stemLength: CGFloat = 22
                let pointX = x(forHours: moment.hours)
                Circle()
                    .fill(moment.tint)
                    .frame(width: 7, height: 7)
                    .position(x: pointX, y: Self.timelineY)
                    .opacity(index < shownMoments ? 1 : 0)
                Rectangle()
                    .fill(moment.tint.opacity(0.5))
                    .frame(width: 1.5, height: stemLength)
                    .position(x: pointX, y: Self.timelineY + (above ? -stemLength / 2 : stemLength / 2))
                    .opacity(index < shownMoments ? 1 : 0)
            }
        }
        .opacity(beat == .answer ? 0 : (isDay ? 1 : 0.55))
        .accessibilityHidden(true)
    }

    private var cards: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.day.enumerated()), id: \.element.id) { index, moment in
                let shown = index < shownMoments || beat >= .answer
                let above = index.isMultiple(of: 2)
                let forgotten = beat == .question && index < forgottenMoments
                let halfRemembered = forgotten && showsFingertips && moment.icon == Self.halfRememberedIcon
                card(moment, forgotten: forgotten)
                    .opacity(shown ? (forgotten ? (halfRemembered ? 0.85 : 0.4) : 1) : 0)
                    .scaleEffect(
                        shown || reduceMotion ? (halfRemembered ? 1.06 : 1) : 0.82,
                        anchor: above ? .bottom : .top
                    )
                    .rotationEffect(.degrees(beat >= .answer ? fanOffset(index) * 4 : 0))
                    .position(cardCenter(index))
                    .zIndex(Double(index))
            }
        }
        // Reduce Motion: the cards fade into the stack rather than fly to it.
        .id(reduceMotion && beat >= .answer ? 1 : 0)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// A card on the timeline. Forgotten, it keeps its kind and colour's ghost
    /// but its title turns into bars: you know it was a paper, not what it said.
    private func card(_ moment: Moment, forgotten: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [moment.tint.opacity(0.9), moment.tint.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: moment.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(height: 48)
            .saturation(forgotten ? 0 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(moment.kind.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    Text(moment.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(forgotten ? 0 : 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: 72, height: 7)
                        Capsule().frame(width: 54, height: 7)
                    }
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .padding(.top, 3)
                    .opacity(forgotten ? 1 : 0)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(forgotten ? 0.04 : 0.16), radius: 8, y: 4)
    }

    private var answerHeadline: some View {
        VStack(spacing: 14) {
            ForeverLMMark(width: 150, motion: .drifting)
            Text("ForeverLM makes it all seamless.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Everything you read, hear and watch, right at your fingertips.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .opacity(beat == .answer ? 1 : 0)
        .offset(y: beat == .answer || reduceMotion ? 0 : 10)
        .position(x: Self.stageSize.width / 2, y: 128)
    }

    private var fingertips: some View {
        VStack(spacing: 6) {
            Text("“I’ve seen this idea before, in that book…”")
                .italic()
            Text("If only it were right there at your fingertips.")
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .opacity(beat == .question && showsFingertips ? 1 : 0)
        .position(x: Self.stageSize.width / 2, y: 438)
    }

    private func x(forHours hours: Double) -> CGFloat {
        let clamped = min(max(hours, Self.hoursSpan.lowerBound), Self.hoursSpan.upperBound)
        let fraction = (clamped - Self.hoursSpan.lowerBound)
            / (Self.hoursSpan.upperBound - Self.hoursSpan.lowerBound)
        let span = Self.timelineSpan
        return span.lowerBound + CGFloat(fraction) * (span.upperBound - span.lowerBound)
    }

    /// Where a card sits: on its time along the day, alternately above and
    /// below the line, then fanned into one stack under the mark.
    private func cardCenter(_ index: Int) -> CGPoint {
        if beat >= .answer {
            let offset = fanOffset(index)
            return CGPoint(x: Self.stageSize.width / 2 + offset * 50, y: 352 + abs(offset) * 5)
        }
        let gap = 22 + Self.cardSize.height / 2
        let above = index.isMultiple(of: 2)
        return CGPoint(
            x: x(forHours: Self.day[index].hours),
            y: Self.timelineY + (above ? -gap : gap)
        )
    }

    private func fanOffset(_ index: Int) -> CGFloat {
        CGFloat(index) - CGFloat(Self.day.count - 1) / 2
    }

    static func clockText(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        var components = DateComponents()
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Here’s how it works.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            promise(
                icon: Self.rememberIcon,
                // The learner writes their own cards (product owner,
                // 2026-11-08: "It shouldn't just be AI making those cards"),
                // so the promise names the writing as theirs.
                title: "Remember what you read.",
                text: "ForeverLM keeps track of what you read. Write what you want to keep in your own words, and it quizzes you until it sticks."
            )
            promise(
                icon: Self.yourAIIcon,
                title: "You’re in charge of your AI.",
                text: "Pick the models on your OpenRouter API key, at cost, or free ones. It works with the AI app you already pay for, too."
            )
            VStack(alignment: .leading, spacing: 12) {
                promise(
                    icon: Self.yourDataIcon,
                    title: "You’re in charge of your data.",
                    text: "Your library lives on this Mac and syncs through your own iCloud. ForeverLM keeps no copy of your chats."
                )
                VStack(alignment: .leading, spacing: 10) {
                    Text("The free 5 GB of iCloud fills fast once papers and audio sync, so iCloud+ \(ICloudStorage.recommendedPlan) works best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ICloudStorageNotices()
                }
                .padding(.leading, 50)
            }
            // What ForeverLM costs, said once at the start (product owner,
            // 2026-10-10): free, MCP included; a price only
            // while the account server sells one.
            Text(EarlyUserDealOffer.welcomeLine(access: ManagedAI.appAccess))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("welcome.price")
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 40)
    }

    private func promise(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
    }

    /// Plays the story forward on a clock. Skip can jump ahead at any point,
    /// so every beat only ever moves forward.
    private func play() async {
        if startsAtEnd {
            beat = .howItWorks
            return
        }
        guard beat == .day else { return }
        if reduceMotion {
            shownMoments = Self.day.count
            clock = Self.hoursSpan.upperBound
            guard await pause(3) else { return }
            advance(to: .question)
            forgottenMoments = Self.day.count
            showsFingertips = true
            guard await pause(4) else { return }
            advance(to: .answer)
            return
        }
        guard await pause(0.5) else { return }
        for (index, moment) in Self.day.enumerated() {
            guard beat == .day else { return }
            withAnimation(.easeInOut(duration: 0.45)) { clock = moment.hours }
            guard await pause(0.2) else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { shownMoments = index + 1 }
            guard await pause(0.42) else { return }
        }
        withAnimation(.easeInOut(duration: 0.6)) { clock = Self.hoursSpan.upperBound }
        guard await pause(1.1) else { return }
        advance(to: .question)
        guard await pause(0.5) else { return }
        // A week goes by: the titles go, oldest first.
        for index in Self.day.indices {
            withAnimation(.easeInOut(duration: 0.8)) { forgottenMoments = index + 1 }
            guard await pause(0.14) else { return }
        }
        guard await pause(0.9) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { showsFingertips = true }
        guard await pause(3.4) else { return }
        advance(to: .answer)
    }

    private func advance(to next: Beat) {
        guard next > beat else { return }
        let duration = reduceMotion ? 0.2 : (next > .answer ? 0.35 : 0.7)
        withAnimation(.easeInOut(duration: duration)) { beat = next }
    }

    /// False once the story is skipped to the end or the view goes away.
    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return false
        }
        return beat < .answer
    }
}

/// A silent screen recording that loops beside a welcome page. The clips are
/// recorded from a demo library, never a learner's own, and ship in
/// WelcomeClipsResources, whose README is the shot list.
struct WelcomeClipPlayer: NSViewRepresentable {
    let url: URL

    static func url(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "WelcomeClipsResources")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.looper?.disableLooping()
        coordinator.player?.pause()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    final class PlayerLayerView: NSView {
        let playerLayer: AVPlayerLayer = {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            return layer
        }()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func makeBackingLayer() -> CALayer { playerLayer }
    }
}

/// The mark setup puts on the option it suggests. Every choice in setup has
/// one, with a line beside it saying why (product owner, 2026-09-22).
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}
