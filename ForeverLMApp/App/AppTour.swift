import SwiftUI

// The tour after Setup: the window's own controls, one at a time, under a
// spotlight, with a card of a few words beside each. Where the step is
// something to do (open the Library, open a source, drag a chat beside it),
// the learner does it on the real control and the tour moves on by itself;
// the dimming never takes a click, so nothing is ever in the way (product
// owner, 2026-11-21: "a proper tutorial … what they can click and … how they
// can drag stuff around … very intuitive and not too much text").

// MARK: - Spots

/// A control or pane the tour can point at. Each one marks itself with
/// `appTourSpot(_:)`; the overlay reads where they are on screen.
enum AppTourSpot: Hashable, Sendable {
    case library, libraryPane, home, chat, memory, space, sidebarToggle, voice, settings
}

struct AppTourSpotKey: PreferenceKey {
    static let defaultValue: [AppTourSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AppTourSpot: Anchor<CGRect>], nextValue: () -> [AppTourSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a place the tour can spotlight.
    func appTourSpot(_ spot: AppTourSpot) -> some View {
        anchorPreference(key: AppTourSpotKey.self, value: .bounds) { [spot: $0] }
    }
}

// MARK: - Steps

/// What the window shows that a step waits for.
struct AppTourSignals: Equatable, Sendable {
    var libraryShown = false
    var readerSourceID: String?
    var paneCount = 1
}

enum AppTourStep: Int, CaseIterable, Sendable {
    case library, openSource, splitChat, ask, memory, space, sidebar, corner

    var spots: [AppTourSpot] {
        switch self {
        case .library: return [.library]
        case .openSource: return [.libraryPane]
        case .splitChat: return [.home]
        case .ask: return [.chat]
        case .memory: return [.memory]
        case .space: return [.space]
        case .sidebar: return [.sidebarToggle]
        case .corner: return [.voice, .settings]
        }
    }

    var title: String {
        switch self {
        case .library: return "Your Library"
        case .openSource: return "Open a source"
        case .splitChat: return "Drag to split"
        case .ask: return "Ask about it"
        case .memory: return "Memory"
        case .space: return "Space"
        case .sidebar: return "Make room"
        case .corner: return "Voice and Settings"
        }
    }

    var line: String {
        switch self {
        case .library: return "Everything you add lands here. Click it."
        case .openSource: return "Click any source to read it."
        case .splitChat: return "Drag Home to the right edge of the window."
        case .ask: return "The chat sees what you\u{2019}re reading."
        case .memory: return "A few cards a day, so it stays."
        case .space: return "Your notebooks, Pages and ideas."
        case .sidebar: return "This folds the sidebar away and back."
        case .corner: return "Talk to ForeverLM, or change anything."
        }
    }

    /// Steps the learner does on the real control; the rest are read.
    var isAction: Bool { waitsFor != nil }

    private var waitsFor: ((AppTourSignals, AppTourSignals) -> Bool)? {
        switch self {
        case .library:
            return { now, _ in now.libraryShown }
        case .openSource:
            return { now, entry in now.readerSourceID != nil && now.readerSourceID != entry.readerSourceID }
        case .splitChat:
            return { now, entry in now.paneCount > entry.paneCount }
        default:
            return nil
        }
    }

    /// Whether the learner has done what this step asks, against what the
    /// window showed when the step began.
    func isDone(now: AppTourSignals, entry: AppTourSignals) -> Bool {
        waitsFor?(now, entry) ?? false
    }

    var next: AppTourStep? { AppTourStep(rawValue: rawValue + 1) }
}

/// One window's tour: which step is up and what the window showed when it began.
@MainActor
@Observable
final class AppTourModel {
    private(set) var step: AppTourStep?
    private var entry = AppTourSignals()
    private var signals = AppTourSignals()
    private var advancing = false

    var isRunning: Bool { step != nil }

    func start(_ signals: AppTourSignals) {
        self.signals = signals
        begin(.library)
    }

    func stop() {
        step = nil
        advancing = false
    }

    func advance() {
        guard let step else { return }
        if let next = step.next { begin(next) } else { stop() }
    }

    /// The window changed: a step whose action is done moves on after a
    /// moment, so the learner sees what their click did first.
    func observe(_ signals: AppTourSignals) {
        self.signals = signals
        guard let step, !advancing, step.isDone(now: signals, entry: entry) else { return }
        advancing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard self.step == step else { return }
            self.advance()
        }
    }

    private func begin(_ next: AppTourStep) {
        entry = signals
        advancing = false
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
        // Already done as it begins (the Library was open): move on.
        observe(signals)
    }
}

// MARK: - Placement

enum AppTourLayout {
    static let cardWidth: CGFloat = 268
    static let cardHeight: CGFloat = 132
    static let gap: CGFloat = 14
    static let margin: CGFloat = 16

    /// The card's centre: beside a control on the window's left edge, inside
    /// the bottom of a pane, below anything else, and in the middle when the
    /// spot is not on screen. Always kept inside the window.
    static func cardCenter(spot: CGRect?, in size: CGSize) -> CGPoint {
        let halfW = cardWidth / 2, halfH = cardHeight / 2
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x, margin + halfW), max(margin + halfW, size.width - margin - halfW)),
                y: min(max(point.y, margin + halfH), max(margin + halfH, size.height - margin - halfH))
            )
        }
        guard let spot, !spot.isEmpty, spot.width.isFinite else {
            return clamp(CGPoint(x: size.width / 2, y: size.height / 2))
        }
        let isPane = spot.width > cardWidth && spot.height > cardHeight * 2
        if isPane {
            return clamp(CGPoint(x: spot.midX, y: spot.maxY - gap - halfH - 24))
        }
        if spot.maxX < size.width * 0.3 {
            return clamp(CGPoint(x: spot.maxX + gap + halfW, y: spot.midY))
        }
        return clamp(CGPoint(x: spot.midX, y: spot.maxY + gap + halfH))
    }
}

// MARK: - Overlay

struct AppTourOverlay: View {
    let model: AppTourModel
    let spots: [AppTourSpot: Anchor<CGRect>]
    /// How far the window's titlebar band reaches above this overlay, so the
    /// dimming covers it and the sidebar toggle in it can be lit.
    var bandAbove: CGFloat = 0
    var onEnd: () -> Void

    @State private var pulse = false

    var body: some View {
        if let step = model.step {
            GeometryReader { proxy in
                let hole = holeRect(for: step, proxy: proxy)
                ZStack(alignment: .topLeading) {
                    scrim(hole: hole, size: proxy.size)
                    if let hole {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: hole.width, height: hole.height)
                            .scaleEffect(pulse ? 1.04 : 1)
                            .opacity(pulse ? 0.35 : 1)
                            .position(x: hole.midX, y: hole.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    card(step)
                        .frame(width: AppTourLayout.cardWidth)
                        .position(AppTourLayout.cardCenter(spot: hole, in: proxy.size))
                        .id(step)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                .animation(.easeInOut(duration: 0.25), value: hole)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
            .onDisappear { pulse = false }
            .transition(.opacity)
        }
    }

    private func holeRect(for step: AppTourStep, proxy: GeometryProxy) -> CGRect? {
        let rects = step.spots.compactMap { spots[$0].map { proxy[$0] } }
            .filter { !$0.isEmpty && $0.width.isFinite }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -6)
    }

    /// Dims all but the hole and takes no clicks: the learner works the real
    /// window through it, drags included.
    private func scrim(hole: CGRect?, size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(x: 0, y: -bandAbove, width: size.width, height: size.height + bandAbove))
            if let hole {
                path.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10), style: .continuous)
            }
        }
        .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func card(_ step: AppTourStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                    .textSelection(.disabled)
                Spacer(minLength: 8)
                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help("End the tour")
                .accessibilityLabel("End the tour")
            }
            Text(step.line)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            HStack(spacing: 5) {
                ForEach(AppTourStep.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 5, height: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(AppTourStep.allCases.count)")
                Spacer()
                if step.isAction {
                    Button("Skip") { model.advance() }
                        .buttonStyle(.hoverWash)
                        .foregroundStyle(.secondary)
                } else {
                    Button(step.next == nil ? "Done" : "Next") {
                        if step.next == nil { onEnd() } else { model.advance() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

extension Notification.Name {
    /// Posted by the app menu's "Take the Tour" item; the active Studio window
    /// starts the tour again.
    static let showAppTour = Notification.Name("showAppTour")
}
