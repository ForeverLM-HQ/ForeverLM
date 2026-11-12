import CarPlay
import Combine
import Foundation
import UIKit

// CarPlay front door: connect and talk. The car starts the
// personal voice assistant on OpenAI Realtime (`MobileRealtimeVoice.startAssistant`,
// `MobileRealtimeAssistant`), which knows the learner's recent work, goals and
// plans and can open any source to talk about or quiz on (product owner,
// 2026-11-07: "I need to be able to just talk to this AI assistant and have it
// ... just work"). Asked for their review, it runs the cards itself. The
// template follows whatever voice conversation is running, so a Review by
// Voice started on the phone shows in the car too. The approved CarPlay category is voice-based conversation, so the in-car surface
// deliberately uses Apple's Voice Control template rather than presenting the
// audio-app Now Playing template. The shared controller outlives the SwiftUI
// window scene, which is not guaranteed to be connected while driving with the
// phone locked.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceStateObserver: AnyCancellable?
    private var voiceTemplate: CPVoiceControlTemplate?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let realtime = MobileRealtimeVoice.controller
        let template = makeVoiceTemplate()
        voiceTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        voiceStateObserver = Publishers.CombineLatest3(realtime.$phase, realtime.$statusText, realtime.$needsSignIn)
            .sink { [weak self] phase, statusText, needsSignIn in
                guard let self else { return }
                let identifier = self.voiceStateIdentifier(for: phase, statusText: statusText, needsSignIn: needsSignIn)
                self.voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
            }

        if realtime.phase == .idle {
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
        voiceTemplate = nil
        // Do not trust the last rendered phase as the ownership authority. A
        // disconnect can arrive while async preflight is still suspended; End
        // must invalidate that pending start or it could arm the microphone
        // after the car scene is already gone.
        Task {
            await MobileRealtimeVoice.controller.end()
        }
    }

    // MARK: - Voice

    /// Starts the assistant, or resumes the conversation that failed (a
    /// dropped connection that could not come back, keeping what was said).
    private func startVoiceAgent() {
        let realtime = MobileRealtimeVoice.controller

        voiceTemplate?.activateVoiceControlState(withIdentifier: "listening")

        Task { @MainActor in
            if realtime.phase == .failed {
                await realtime.resume()
            } else if realtime.phase == .idle {
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

    private func endVoiceSession() {
        // The controller is authoritative; rendered CarPlay state can lag
        // during async startup or a route transition.
        Task {
            await MobileRealtimeVoice.controller.end()
        }
    }

    /// The conversation's phases on the template's five states.
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
