import CarPlay
import Combine
import Foundation
import OSLog
import UIKit

// CarPlay front door: connect and talk. Since 2026-11-07 the car starts the
// personal voice assistant on OpenAI Realtime (`MobileRealtimeVoice.startAssistant`,
// `MobileRealtimeAssistant`), which knows the learner's recent work, goals and
// plans and can open any source to talk about or quiz on (product owner,
// 2026-11-07: "I need to be able to just talk to this AI assistant and have it
// ... just work"). Asked for today's memory review, it hands over to the
// turn-by-turn conversation (`MobileVoiceConversationController`), which owns
// cards and grading; the template follows whichever of the two is running. The
// approved CarPlay category is voice-based conversation, so the in-car surface
// deliberately uses Apple's Voice Control template rather than presenting the
// audio-app Now Playing template. The shared controller outlives the SwiftUI
// window scene, which is not guaranteed to be connected while driving with the
// phone locked.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "CarPlay")

    private var interfaceController: CPInterfaceController?
    private var voiceStateObserver: AnyCancellable?
    private var contextSourcesObserver: AnyCancellable?
    private var voiceTemplate: CPVoiceControlTemplate?
    private var contextSourcesTemplate: CPListTemplate?
    private var contextSources: [CarPlayContextSource] = []
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let voiceController = MobileVoiceConversationController.shared
        let realtime = MobileRealtimeVoice.controller
        let template = makeVoiceTemplate()
        voiceTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        voiceStateObserver = Publishers.CombineLatest(
            Publishers.CombineLatest3(realtime.$phase, realtime.$statusText, realtime.$needsSignIn),
            Publishers.CombineLatest3(voiceController.$phase, voiceController.$statusText, voiceController.$needsSignIn)
        )
            .sink { [weak self] assistant, turnByTurn in
                guard let self else { return }
                let identifier: String
                if assistant.0 != .idle || assistant.2 {
                    identifier = self.voiceStateIdentifier(for: assistant.0, statusText: assistant.1, needsSignIn: assistant.2)
                } else {
                    identifier = self.voiceStateIdentifier(for: turnByTurn.0, statusText: turnByTurn.1, needsSignIn: turnByTurn.2)
                }
                self.voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
            }

        contextSourcesObserver = voiceController.$loadedSources
            .map { $0.map(CarPlayContextSource.init) }
            .removeDuplicates()
            .sink { [weak self] sources in
                self?.contextSourcesDidChange(sources)
            }

        if voiceController.phase == .idle, realtime.phase == .idle {
            startVoiceAgent()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
        voiceStateObserver?.cancel()
        voiceStateObserver = nil
        contextSourcesObserver?.cancel()
        contextSourcesObserver = nil
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        voiceTemplate = nil
        contextSourcesTemplate = nil
        contextSources = []
        // Do not trust the last rendered phase as the ownership authority. A
        // disconnect can arrive while async preflight is still suspended; End
        // must invalidate that pending start or it could arm the microphone
        // after the car scene is already gone.
        Task {
            await MobileRealtimeVoice.controller.end()
            await MobileVoiceConversationController.shared.end()
        }
    }

    // MARK: - Voice

    /// Starts the assistant, or resumes the conversation that failed (a
    /// dropped connection that could not come back, keeping what was said).
    private func startVoiceAgent() {
        let realtime = MobileRealtimeVoice.controller
        let turnByTurn = MobileVoiceConversationController.shared

        voiceTemplate?.activateVoiceControlState(withIdentifier: "listening")

        Task { @MainActor in
            if realtime.phase == .failed {
                await realtime.resume()
            } else if turnByTurn.phase == .failed {
                await turnByTurn.resume()
            } else if realtime.phase == .idle, turnByTurn.phase == .idle {
                await MobileRealtimeVoice.startAssistant(setting: .car)
            }
        }
    }

    private func makeVoiceTemplate() -> CPVoiceControlTemplate {
        // CarPlay owns this layout, but CPVoiceControlState accepts animated
        // images. Keep active conversation states wordless and use the same
        // fluid-orb language as the phone and Mac surfaces.
        let listening = CPVoiceControlState(
            identifier: "listening",
            titleVariants: nil,
            image: CarPlayVoiceOrbRenderer.image(for: .listening),
            repeats: true
        )
        let thinking = CPVoiceControlState(
            identifier: "thinking",
            titleVariants: nil,
            image: CarPlayVoiceOrbRenderer.image(for: .thinking),
            repeats: true
        )
        let speaking = CPVoiceControlState(
            identifier: "speaking",
            titleVariants: nil,
            image: CarPlayVoiceOrbRenderer.image(for: .speaking),
            repeats: true
        )
        let unavailable = CPVoiceControlState(
            identifier: "unavailable",
            titleVariants: ["Voice unavailable"],
            image: UIImage(systemName: "exclamationmark.circle"),
            repeats: false
        )
        let signIn = CPVoiceControlState(
            identifier: "sign-in",
            titleVariants: ["Open ForeverLM on iPhone"],
            image: UIImage(systemName: "iphone"),
            repeats: false
        )
        // CPVoiceControlTemplate accepts at most five states. Ready/connecting/
        // ending are brief transport phases and intentionally share the calm
        // listening orb instead of pushing the error/sign-in states off the end.
        let states = [listening, thinking, speaking, unavailable, signIn]

        let template = CPVoiceControlTemplate(voiceControlStates: states)
        if #available(iOS 26.4, *) {
            configureVoiceActionButtons(on: template)
        }
        return template
    }

    @available(iOS 26.4, *)
    private func configureVoiceActionButtons(on template: CPVoiceControlTemplate) {
        if contextSources.isEmpty {
            template.trailingNavigationBarButtons = []
        } else {
            let sourcesButton = CPBarButton(title: "Sources") { [weak self] _ in
                self?.showContextSources()
            }
            sourcesButton.buttonStyle = .rounded
            template.trailingNavigationBarButtons = [sourcesButton]
        }

        for state in template.voiceControlStates {
            switch state.identifier {
            case "listening", "thinking", "speaking":
                guard let endImage = UIImage(systemName: "xmark.circle.fill") else { continue }
                // A CPButton belongs to one voice-control state. Reusing one
                // instance across three states can leave the visible button
                // detached from its handler after CarPlay switches state.
                let endButton = CPButton(image: endImage) { [weak self] _ in
                    self?.endVoiceSession()
                }
                endButton.title = "End"
                state.actionButtons = [endButton]
            case "unavailable":
                guard let startImage = UIImage(systemName: "mic.circle.fill") else { continue }
                let startButton = CPButton(image: startImage) { [weak self] _ in
                    self?.startVoiceAgent()
                }
                startButton.title = "Start"
                state.actionButtons = [startButton]
            default:
                state.actionButtons = []
            }
        }
    }

    private func contextSourcesDidChange(_ sources: [CarPlayContextSource]) {
        guard sources != contextSources else { return }
        contextSources = sources

        if #available(iOS 26.4, *), let voiceTemplate {
            configureVoiceActionButtons(on: voiceTemplate)
        }
        refreshContextSourcesTemplateIfNeeded()
    }

    private func showContextSources() {
        guard !contextSources.isEmpty, let interfaceController else { return }

        let template = CPListTemplate(title: "In Context", sections: [])
        template.emptyViewTitleVariants = ["No sources in context"]
        template.emptyViewSubtitleVariants = ["Return to the conversation"]
        contextSourcesTemplate = template
        refreshContextSourcesTemplateIfNeeded()

        interfaceController.pushTemplate(template, animated: true) { [weak self, weak template] success, error in
            guard !success else { return }
            if self?.contextSourcesTemplate === template {
                self?.contextSourcesTemplate = nil
            }
            if let error {
                Self.logger.error("Could not show CarPlay context sources: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func refreshContextSourcesTemplateIfNeeded() {
        guard let template = contextSourcesTemplate else { return }

        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()

        let visibleSources = Array(contextSources.prefix(CPListTemplate.maximumItemCount))
        let rows = visibleSources.map { source in
            let item = CPListItem(
                text: source.title,
                detailText: source.detailText,
                image: CarPlaySourceThumbnail.fallback(for: source.sourceType)
            )
            return (source, item)
        }
        template.updateSections([CPListSection(items: rows.map(\.1))])

        for (source, item) in rows {
            thumbnailTasks[source.id] = Task { [weak self, weak item] in
                guard let image = await self?.thumbnail(for: source),
                      !Task.isCancelled else { return }
                item?.setImage(image)
            }
        }
    }

    private func thumbnail(for source: CarPlayContextSource) async -> UIImage? {
        if source.sourceType == "paper",
           let paper = await MobileSourceFileStore.shared.fetchPaperThumbnail(sourceID: source.id) {
            return paper
        }
        guard let url = source.thumbnailURL else { return nil }

        let cacheKey = url.absoluteString
        if let cached = ImageCache.shared.image(for: cacheKey) {
            return cached
        }
        if let diskImage = await Task.detached(priority: .utility, operation: {
            ThumbnailDiskCache.shared.cachedImage(for: cacheKey)
        }).value {
            ImageCache.shared.set(diskImage, for: cacheKey)
            return diskImage
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return nil
            }
            guard let image = await Task.detached(priority: .utility, operation: {
                UIImage(data: data)
            }).value else {
                return nil
            }
            ImageCache.shared.set(image, for: cacheKey, toDisk: true)
            return image
        } catch {
            return nil
        }
    }

    private func voiceStateIdentifier(
        for phase: MobileVoiceConversationController.Phase,
        statusText: String,
        needsSignIn: Bool
    ) -> String {
        if needsSignIn { return "sign-in" }
        switch statusText {
        case "Listening": return "listening"
        case "Thinking": return "thinking"
        case "Speaking": return "speaking"
        default:
            switch phase {
            case .idle, .connecting: return "listening"
            case .live: return "listening"
            case .ending: return "listening"
            case .failed: return "unavailable"
            }
        }
    }

    private func endVoiceSession() {
        // The controllers are authoritative; rendered CarPlay state can lag
        // during async startup or a route transition.
        Task {
            await MobileRealtimeVoice.controller.end()
            await MobileVoiceConversationController.shared.end()
        }
    }

    /// The assistant's phases on the same five states.
    private func voiceStateIdentifier(
        for phase: RealtimeVoiceController.Phase,
        statusText: String,
        needsSignIn: Bool
    ) -> String {
        if needsSignIn { return "sign-in" }
        switch statusText {
        case "Thinking": return "thinking"
        case "Speaking": return "speaking"
        default:
            return phase == .failed ? "unavailable" : "listening"
        }
    }
}

private struct CarPlayContextSource: Equatable {
    let id: String
    let title: String
    let detailText: String
    let sourceType: String
    let thumbnailURL: URL?

    init(source: MobileCloudSource) {
        id = source.id
        title = source.title
        sourceType = source.sourceType.lowercased()
        thumbnailURL = source.thumbnailURL

        let typeLabel = source.sourceType.replacingOccurrences(of: "_", with: " ").capitalized
        if let subtitle = source.citationSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty {
            detailText = "\(typeLabel) · \(subtitle)"
        } else {
            detailText = typeLabel
        }
    }
}

private enum CarPlaySourceThumbnail {
    static func fallback(for sourceType: String) -> UIImage? {
        let symbolName: String
        let tint: UIColor
        switch sourceType {
        case "paper":
            symbolName = "doc.text.magnifyingglass"
            tint = .systemPurple
        case "podcast":
            symbolName = "headphones"
            tint = .systemOrange
        case "book":
            symbolName = "book.closed"
            tint = .systemGreen
        case "course":
            symbolName = "graduationcap"
            tint = .systemIndigo
        case "meeting":
            symbolName = "person.2.wave.2"
            tint = .systemTeal
        case "video":
            symbolName = "play.rectangle"
            tint = .systemRed
        case "xpost", "x_post":
            symbolName = "bubble.left.and.bubble.right"
            tint = .label
        case "manual":
            symbolName = "link"
            tint = .secondaryLabel
        default:
            symbolName = "doc.richtext"
            tint = .systemBlue
        }
        return UIImage(systemName: symbolName)?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}

/// Produces small, bounded animations for the system-owned CarPlay voice
/// template. Frames are generated only when CarPlay connects; playback itself
/// is handled by CarPlay and does not add a display-link or polling loop.
private enum CarPlayVoiceOrbRenderer {
    enum Activity {
        case listening
        case thinking
        case speaking
    }

    static func image(for activity: Activity) -> UIImage? {
        let frameCount = 16
        let size = CGSize(width: 132, height: 132)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let frames = (0..<frameCount).map { index in
            renderer.image { rendererContext in
                draw(
                    activity: activity,
                    phase: CGFloat(index) / CGFloat(frameCount) * .pi * 2,
                    in: rendererContext.cgContext,
                    size: size
                )
            }
        }

        return UIImage.animatedImage(with: frames, duration: duration(for: activity))
    }

    private static func duration(for activity: Activity) -> TimeInterval {
        switch activity {
        case .listening: return 2.2
        case .thinking: return 1.55
        case .speaking: return 0.95
        }
    }

    private static func draw(
        activity: Activity,
        phase: CGFloat,
        in context: CGContext,
        size: CGSize
    ) {
        let palette = colors(for: activity)
        let pulse: CGFloat
        switch activity {
        case .listening: pulse = sin(phase) * 2.2
        case .thinking: pulse = sin(phase * 2) * 2.8
        case .speaking: pulse = sin(phase * 2) * 4.2
        }

        let sphereRect = CGRect(
            x: 14 - pulse * 0.35,
            y: 14 + pulse * 0.28,
            width: 104 + pulse * 0.70,
            height: 104 - pulse * 0.56
        )

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 5), blur: 11, color: palette[0].withAlphaComponent(0.34).cgColor)
        context.setFillColor(palette[0].cgColor)
        context.fillEllipse(in: sphereRect)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: sphereRect)
        context.clip()

        guard let baseGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: palette.map(\.cgColor) as CFArray,
            locations: [0, 0.46, 1]
        ) else {
            context.restoreGState()
            return
        }
        context.drawLinearGradient(
            baseGradient,
            start: CGPoint(x: sphereRect.minX, y: sphereRect.minY),
            end: CGPoint(x: sphereRect.maxX, y: sphereRect.maxY),
            options: []
        )

        let bloomCenter = CGPoint(
            x: sphereRect.midX + cos(phase) * 24,
            y: sphereRect.midY + sin(phase * 0.82) * 22
        )
        if let bloom = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [palette[2].withAlphaComponent(0.85).cgColor, UIColor.clear.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                bloom,
                startCenter: bloomCenter,
                startRadius: 0,
                endCenter: bloomCenter,
                endRadius: 58,
                options: [.drawsAfterEndLocation]
            )
        }

        let highlightCenter = CGPoint(x: sphereRect.minX + 32, y: sphereRect.minY + 27)
        if let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.white.withAlphaComponent(0.52).cgColor, UIColor.clear.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                highlight,
                startCenter: highlightCenter,
                startRadius: 0,
                endCenter: highlightCenter,
                endRadius: 48,
                options: []
            )
        }

        context.restoreGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.24).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: sphereRect.insetBy(dx: 0.6, dy: 0.6))
    }

    private static func colors(for activity: Activity) -> [UIColor] {
        switch activity {
        case .listening:
            return [
                UIColor(red: 0.12, green: 0.48, blue: 1, alpha: 1),
                UIColor(red: 0.12, green: 0.85, blue: 0.92, alpha: 1),
                UIColor(red: 0.48, green: 0.30, blue: 1, alpha: 1),
            ]
        case .thinking:
            return [
                UIColor(red: 0.27, green: 0.20, blue: 0.78, alpha: 1),
                UIColor(red: 0.62, green: 0.25, blue: 0.95, alpha: 1),
                UIColor(red: 0.20, green: 0.70, blue: 1, alpha: 1),
            ]
        case .speaking:
            return [
                UIColor(red: 0.95, green: 0.20, blue: 0.40, alpha: 1),
                UIColor(red: 0.58, green: 0.24, blue: 0.92, alpha: 1),
                UIColor(red: 1, green: 0.58, blue: 0.18, alpha: 1),
            ]
        }
    }
}
