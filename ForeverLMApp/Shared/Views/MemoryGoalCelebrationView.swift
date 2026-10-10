import SwiftUI

/// The moment today's review goal is met: one two-second burst of confetti
/// over the chat and one line naming the streak. Shown once, by whichever
/// client the learner was on when the clock crossed the line; it draws
/// nothing the learner can act on, and it goes away by itself.
///
/// SwiftUI only, so the Mac's chat panel and the phone's review screen show
/// the same thing. Particles are laid out once from a fixed seed and drawn
/// per frame in a `Canvas`; no per-frame allocation.
///
/// The start time is `@State`, not a stored `let`: the hosts rebuild this view
/// on every goal-tracker heartbeat and on every streamed token, and a plain
/// property would be re-initialised each time, restarting the burst for as
/// long as the parent kept updating — which is how a two-second animation
/// ran on for the length of the tutor's reply.
struct MemoryGoalCelebrationView: View {
    let goalMinutes: Int
    let streak: Int
    /// Called once the animation has run its course.
    let onFinished: () -> Void

    @State private var startedAt = Date()
    private static let duration: TimeInterval = 2.0
    private static let labelFadeIn: TimeInterval = 0.2
    private static let labelHold: TimeInterval = 1.3

    /// The same burst on every showing, laid out once per process.
    private static let particles: [Particle] = {
        var generator = SeededGenerator(seed: 0x5EED_0F0D)
        return (0..<90).map { _ in Particle(using: &generator) }
    }()

    init(goalMinutes: Int, streak: Int, onFinished: @escaping () -> Void) {
        self.goalMinutes = goalMinutes
        self.streak = streak
        self.onFinished = onFinished
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                Canvas { graphics, size in
                    for particle in Self.particles {
                        let t = elapsed - particle.delay
                        guard t > 0 else { continue }
                        let progress = t / (Self.duration - particle.delay)
                        guard progress < 1 else { continue }
                        let x = particle.x * size.width + sin(t * particle.sway + particle.phase) * 18
                        let y = -12 + t * particle.speed * size.height * 0.42
                        guard y < size.height + 12 else { continue }
                        let fade = progress > 0.75 ? 1 - (progress - 0.75) / 0.25 : 1
                        var rect = CGRect(x: 0, y: 0, width: particle.size, height: particle.size * 0.55)
                        rect.origin = CGPoint(x: -rect.width / 2, y: -rect.height / 2)
                        var transform = CGAffineTransform(translationX: x, y: y)
                        transform = transform.rotated(by: t * particle.spin)
                        let path = Path(roundedRect: rect, cornerRadius: 1).applying(transform)
                        graphics.fill(path, with: .color(particle.color.opacity(fade)))
                    }
                }
                .allowsHitTesting(false)

                label(elapsed: elapsed)
            }
            .onChange(of: elapsed >= Self.duration) { _, done in
                if done { onFinished() }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's review is done. \(streakLine)")
    }

    private var streakLine: String {
        streak <= 1 ? "Streak started" : "\(streak)-day streak"
    }

    @ViewBuilder
    private func label(elapsed: TimeInterval) -> some View {
        let appear = min(1, max(0, elapsed / Self.labelFadeIn))
        let leave = elapsed > Self.labelHold
            ? max(0, 1 - (elapsed - Self.labelHold) / (Self.duration - Self.labelHold))
            : 1
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text(streakLine)
            }
            .font(.title3.weight(.semibold))
            Text("\(goalMinutes) minutes of review, done")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .scaleEffect(0.92 + 0.08 * appear)
        .opacity(appear * leave)
    }

    private struct Particle {
        let x: Double
        let delay: TimeInterval
        let speed: Double
        let sway: Double
        let phase: Double
        let spin: Double
        let size: CGFloat
        let color: Color

        private static let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .blue, .purple, .pink]

        init(using generator: inout SeededGenerator) {
            x = generator.nextUnit()
            // One burst: every piece is in the air within the first tenth of a
            // second, rather than trickling in.
            delay = generator.nextUnit() * 0.1
            speed = 0.8 + generator.nextUnit() * 0.6
            sway = 1.5 + generator.nextUnit() * 2.5
            phase = generator.nextUnit() * .pi * 2
            spin = (generator.nextUnit() - 0.5) * 12
            size = 6 + CGFloat(generator.nextUnit()) * 6
            color = Self.palette[Int(generator.nextUnit() * Double(Self.palette.count)) % Self.palette.count]
        }
    }

    /// A small deterministic generator, so the burst is the same shape on
    /// every showing and needs no system randomness.
    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}
