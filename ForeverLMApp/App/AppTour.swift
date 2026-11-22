import SwiftUI

// The tour after Setup: an interactive demo of the window itself. It opens
// the learner's own Library, lays a labelled map over the window (every icon
// on the strip named, the Library and the sidebar outlined), then lights one
// control at a time with a card of a few words beside it. Nearly every step
// is something to do on the real control (open a source, drag a chat beside
// it, open Memory, open the Space, fold the sidebar), and the tour moves on by
// itself once it is done; the dimming never takes a click, so drags work
// through it (product owner, 2026-11-21: "a proper tutorial … what they can
// click and … how they can drag stuff around … very intuitive and not too
// much text"; "make this actually an interactive demo … pretty clear where
// all the different things are"; "show the person's library").

// MARK: - Spots

/// A control or pane the tour can point at or name. Each one marks itself with
/// `appTourSpot(_:)`; the overlay reads where they are on screen.
enum AppTourSpot: Hashable, Sendable {
    case libraryPane, home, chat, memory, space, sidebarToggle, voice, settings
    /// An icon on the strip, named on the map.
    case icon(String)
    /// An area of the window, outlined and named on the map.
    case region(String)
}

struct AppTourSpotKey: PreferenceKey {
    static let defaultValue: [AppTourSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AppTourSpot: Anchor<CGRect>], nextValue: () -> [AppTourSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a place the tour can spotlight or name. Several
    /// marks on one view all count.
    func appTourSpot(_ spot: AppTourSpot) -> some View {
        transformAnchorPreference(key: AppTourSpotKey.self, value: .bounds) { spots, anchor in
            spots[spot] = anchor
        }
    }
}

// MARK: - Steps

/// What the window shows that a step waits for.
struct AppTourSignals: Equatable, Sendable {
    var readerSourceID: String?
    var paneCount = 1
    var memoryShown = false
    var spaceShown = false
    var sidebarShown = true
}

enum AppTourStep: Int, CaseIterable, Sendable {
    case map, openSource, splitChat, ask, memory, space, sidebar, corner

    var spots: [AppTourSpot] {
        switch self {
        case .map: return []
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
        case .map: return "Where things are"
        case .openSource: return "Your Library"
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
        case .map: return "Places on the left, your work on the right."
        case .openSource: return "Everything you added. Click one to read it."
        case .splitChat: return "Drag Home onto the right edge."
        case .ask: return "The chat sees what you\u{2019}re reading."
        case .memory: return "Click it to see today\u{2019}s cards."
        case .space: return "Click it for notebooks, Pages and ideas."
        case .sidebar: return "Click to fold the sidebar, then again."
        case .corner: return "Talk to ForeverLM, or change anything."
        }
    }

    /// Steps the learner does on the real control; the rest are read.
    var isAction: Bool {
        switch self {
        case .openSource, .splitChat, .memory, .space, .sidebar: return true
        case .map, .ask, .corner: return false
        }
    }

    /// Whether the learner has done what this step asks, against what the
    /// window showed when the step began; `sidebarFlips` counts the sidebar
    /// toggle's changes during the step (folded and brought back is two).
    func isDone(now: AppTourSignals, entry: AppTourSignals, sidebarFlips: Int = 0) -> Bool {
        switch self {
        case .openSource: return now.readerSourceID != nil && now.readerSourceID != entry.readerSourceID
        case .splitChat: return now.paneCount > entry.paneCount
        case .memory: return now.memoryShown
        case .space: return now.spaceShown
        case .sidebar: return sidebarFlips >= 2
        case .map, .ask, .corner: return false
        }
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
    private var sidebarFlips = 0
    private var advancing = false

    var isRunning: Bool { step != nil }

    func start(_ signals: AppTourSignals) {
        self.signals = signals
        begin(.map)
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
    /// moment, so the learner sees what their click opened first.
    func observe(_ signals: AppTourSignals) {
        if signals.sidebarShown != self.signals.sidebarShown { sidebarFlips += 1 }
        self.signals = signals
        guard let step, !advancing,
              step.isDone(now: signals, entry: entry, sidebarFlips: sidebarFlips) else { return }
        advancing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard self.step == step else { return }
            self.advance()
        }
    }

    private func begin(_ next: AppTourStep) {
        entry = signals
        sidebarFlips = 0
        advancing = false
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
        // Already done as it begins (Memory was open): move on.
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

    /// Where the drag hint carries Home to: the middle of the window's right edge.
    static func dropPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 48, y: size.height / 2)
    }
}

// MARK: - Overlay

struct AppTourOverlay: View {
    let model: AppTourModel
    let spots: [AppTourSpot: Anchor<CGRect>]
    /// How far the window's titlebar band reaches above this overlay, so the
    /// dimming covers it and the sidebar toggle in it can be lit.
    var bandAbove: CGFloat = 0
    var homeGlyph = "house"
    var onEnd: () -> Void

    @State private var pulse = false

    var body: some View {
        if let step = model.step {
            GeometryReader { proxy in
                let hole = holeRect(for: step, proxy: proxy)
                ZStack(alignment: .topLeading) {
                    scrim(hole: hole, size: proxy.size)
                    if step == .map {
                        map(proxy: proxy)
                    } else if let hole {
                        ring(hole)
                    }
                    if step == .splitChat {
                        dragHint(from: hole, size: proxy.size)
                    }
                    card(step)
                        .frame(width: AppTourLayout.cardWidth)
                        .position(AppTourLayout.cardCenter(spot: cardSpot(for: step, hole: hole, proxy: proxy), in: proxy.size))
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

    private func rect(_ spot: AppTourSpot, _ proxy: GeometryProxy) -> CGRect? {
        guard let anchor = spots[spot] else { return nil }
        let rect = proxy[anchor]
        return rect.isEmpty || !rect.width.isFinite ? nil : rect
    }

    private func iconRects(_ proxy: GeometryProxy) -> [(String, CGRect)] {
        spots.keys.compactMap { spot -> (String, CGRect)? in
            guard case .icon(let title) = spot, let rect = rect(spot, proxy) else { return nil }
            return (title, rect)
        }
        .sorted { $0.1.minY < $1.1.minY }
    }

    private func regionRects(_ proxy: GeometryProxy) -> [(String, CGRect)] {
        spots.keys.compactMap { spot -> (String, CGRect)? in
            guard case .region(let title) = spot, let rect = rect(spot, proxy) else { return nil }
            return (title, rect)
        }
        .sorted { $0.1.minX < $1.1.minX }
    }

    /// The lit area: the step's controls, or on the map the whole strip.
    private func holeRect(for step: AppTourStep, proxy: GeometryProxy) -> CGRect? {
        let rects = step == .map
            ? iconRects(proxy).map(\.1)
            : step.spots.compactMap { rect($0, proxy) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -6)
    }

    /// The map's card stands in the learner's Library; another step's beside its spot.
    private func cardSpot(for step: AppTourStep, hole: CGRect?, proxy: GeometryProxy) -> CGRect? {
        guard step == .map else { return hole }
        return rect(.libraryPane, proxy) ?? regionRects(proxy).last?.1
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

    private func ring(_ hole: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .frame(width: hole.width, height: hole.height)
            .scaleEffect(pulse ? 1.04 : 1)
            .opacity(pulse ? 0.35 : 1)
            .position(x: hole.midX, y: hole.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Every strip icon named beside it, and each area outlined with its name.
    private func map(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(regionRects(proxy), id: \.0) { title, area in
                let box = area.insetBy(dx: 8, dy: 8)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                mapLabel(title, prominent: true)
                    .fixedSize()
                    // In the middle of the area: the strip's labels sit
                    // at its top and bottom, beside the sidebar's edge.
                    .alignmentGuide(.leading) { dimensions in -(box.midX - dimensions.width / 2) }
                    .alignmentGuide(.top) { dimensions in -(box.midY - dimensions.height / 2) }
            }
            ForEach(iconRects(proxy), id: \.0) { title, icon in
                mapLabel(title, prominent: false)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in -(icon.maxX + 12) }
                    .alignmentGuide(.top) { dimensions in -(icon.midY - dimensions.height / 2) }
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func mapLabel(_ title: String, prominent: Bool) -> some View {
        Text(title)
            .font(.system(size: prominent ? 13 : 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.primary : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black.opacity(0.72)),
                in: Capsule()
            )
            .textSelection(.disabled)
    }

    /// Home's glyph gliding from the strip to the right edge, again and
    /// again, and the edge it lands on lit: the drag, shown rather than told.
    private func dragHint(from home: CGRect?, size: CGSize) -> some View {
        let start = home.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 26, y: size.height / 2)
        let end = AppTourLayout.dropPoint(in: size)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(pulse ? 0.28 : 0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                }
                .frame(width: 72, height: max(0, size.height - 24))
                .position(x: size.width - 48, y: size.height / 2)
            TimelineView(.animation) { context in
                let cycle = 2.6
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                let move = min(1, t / 0.7)
                let eased = move * move * (3 - 2 * move)
                let opacity = t < 0.08 ? t / 0.08 : (t > 0.85 ? max(0, (1 - t) / 0.15) : 1)
                Image(systemName: homeGlyph)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .offset(x: 10, y: 12)
                    }
                    .opacity(opacity)
                    .position(
                        x: start.x + (end.x - start.x) * eased,
                        y: start.y + (end.y - start.y) * eased
                    )
            }
        }
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
