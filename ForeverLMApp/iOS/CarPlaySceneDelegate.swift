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
//
// Asked to play a source itself ("I want to listen to this article"), the
// assistant ends the conversation and the source's narration plays
// (`listen_to_source`, `RealtimeVoiceListen`). The car then shows that
// narration, still on a Voice Control template: its title, Talk to stop it and
// go back to the assistant, and Pause or Play. When it has played to its end,
// or could not be played, the assistant comes back by itself and says so
// (`CarPlayVoiceScreen`).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceStateObserver: AnyCancellable?
    private var voiceTemplate: CPVoiceControlTemplate?
    private var narrationObserver: AnyCancellable?
    private var narrationTemplate: CPVoiceControlTemplate?
    /// The title of the narration on screen; nil while the conversation is.
    private var shownNarrationTitle: String?
    #if DEBUG
    /// The scripted conversation `-foreverlm-uitest-carplay` plays instead of a real one.
    private var scriptTask: Task<Void, Never>?
    #endif

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        MobileRealtimeVoice.isCarConnected = true
        let realtime = MobileRealtimeVoice.controller
        let audio = MobileAudioReviewViewModel.shared
        // Connect and talk: a narration voice started before the drive is
        // not what the car opens on.
        audio.voiceListen = nil
        let template = makeVoiceTemplate()
        voiceTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        #if DEBUG
        if CarPlayVoiceScript.isEnabled {
            scriptTask = CarPlayVoiceScript.play(on: template)
            return
        }
        #endif

        voiceStateObserver = Publishers.CombineLatest3(realtime.$phase, realtime.$statusText, realtime.$needsOwnKey)
            .sink { [weak self] phase, statusText, needsOwnKey in
                guard let self, self.shownNarrationTitle == nil else { return }
                let identifier = self.voiceStateIdentifier(for: phase, statusText: statusText, needsOwnKey: needsOwnKey)
                self.voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
            }

        narrationObserver = Publishers.CombineLatest4(realtime.$phase, audio.$voiceListen, audio.$isPlaying, audio.$currentItem)
            .sink { [weak self] phase, listen, isPlaying, currentItem in
                self?.show(CarPlayVoiceScreen.resolve(
                    conversationIsIdle: phase == .idle,
                    listen: listen,
                    // Until the narration is the player's it is being made or
                    // fetched: on its way, not paused.
                    isPlaying: isPlaying || currentItem?.id != listen?.sourceID
                ))
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
        MobileRealtimeVoice.isCarConnected = false
        #if DEBUG
        scriptTask?.cancel()
        scriptTask = nil
        #endif
        voiceStateObserver?.cancel()
        voiceStateObserver = nil
        voiceTemplate = nil
        narrationObserver?.cancel()
        narrationObserver = nil
        narrationTemplate = nil
        shownNarrationTitle = nil
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
    ///
    /// `narration` is the narration the learner comes back from, which the
    /// assistant opens on.
    private func startVoiceAgent(returningFrom narration: RealtimeVoiceAssistant.NarrationReturn? = nil) {
        let realtime = MobileRealtimeVoice.controller

        voiceTemplate?.activateVoiceControlState(withIdentifier: "listening")

        Task { @MainActor in
            if realtime.phase == .failed {
                await realtime.resume()
            } else if realtime.phase == .idle {
                await MobileRealtimeVoice.startAssistant(setting: .car, returningFrom: narration)
            }
        }
    }

    // MARK: - Narration

    /// Puts the conversation or the narration on the car's screen.
    private func show(_ screen: CarPlayVoiceScreen) {
        switch screen {
        case .conversation:
            guard shownNarrationTitle != nil else { return }
            shownNarrationTitle = nil
            narrationTemplate = nil
            // A fresh template: the one the narration replaced is not shown again.
            let template = makeVoiceTemplate()
            voiceTemplate = template
            interfaceController?.setRootTemplate(template, animated: false, completion: nil)
            let realtime = MobileRealtimeVoice.controller
            template.activateVoiceControlState(withIdentifier: voiceStateIdentifier(
                for: realtime.phase,
                statusText: realtime.statusText,
                needsOwnKey: realtime.needsOwnKey
            ))
        case .narration(let title, let isPlaying):
            if shownNarrationTitle != title || narrationTemplate == nil {
                let template = makeNarrationTemplate(title: title)
                narrationTemplate = template
                shownNarrationTitle = title
                interfaceController?.setRootTemplate(template, animated: false, completion: nil)
            }
            narrationTemplate?.activateVoiceControlState(withIdentifier: isPlaying ? "playing" : "paused")
        case .backToAssistant(let narration):
            // After this publish: taking the narration off changes what is
            // being published right now.
            Task { @MainActor [weak self] in
                self?.returnToAssistant(narration)
            }
        }
    }

    /// The narration's own screen: its title and the mark of what it is doing.
    private func makeNarrationTemplate(title: String) -> CPVoiceControlTemplate {
        let titles = title.isEmpty ? nil : [title]
        let playing = CPVoiceControlState(
            identifier: "playing",
            titleVariants: titles,
            image: UIImage(systemName: "speaker.wave.2.fill"),
            repeats: false
        )
        let paused = CPVoiceControlState(
            identifier: "paused",
            titleVariants: titles,
            image: UIImage(systemName: "pause.fill"),
            repeats: false
        )
        let template = CPVoiceControlTemplate(voiceControlStates: [playing, paused])
        if #available(iOS 26.4, *) {
            configureNarrationActionButtons(on: template)
        }
        return template
    }

    @available(iOS 26.4, *)
    private func configureNarrationActionButtons(on template: CPVoiceControlTemplate) {
        for state in template.voiceControlStates {
            var buttons: [CPButton] = []
            // Talk comes first: CarPlay ignores buttons past its limit
            // (`maximumActionButtonCount`), and the way back to the
            // assistant is the one that must stay.
            if let talkImage = UIImage(systemName: "mic.circle.fill") {
                let talk = CPButton(image: talkImage) { [weak self] _ in
                    self?.talkOverNarration()
                }
                talk.title = "Talk"
                buttons.append(talk)
            }
            let isPlaying = state.identifier == "playing"
            if let image = UIImage(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                let toggle = CPButton(image: image) { _ in
                    MobileAudioReviewViewModel.shared.togglePlayback()
                }
                toggle.title = isPlaying ? "Pause" : "Play"
                buttons.append(toggle)
            }
            state.actionButtons = buttons
        }
    }

    /// Talk: the narration stops where it is and the assistant comes back.
    private func talkOverNarration() {
        let audio = MobileAudioReviewViewModel.shared
        guard let listen = audio.voiceListen else { return }
        returnToAssistant(RealtimeVoiceAssistant.NarrationReturn(
            sourceID: listen.sourceID,
            title: listen.title,
            outcome: .interrupted
        ))
    }

    /// Takes the narration off the screen, once, and starts the assistant on it.
    private func returnToAssistant(_ narration: RealtimeVoiceAssistant.NarrationReturn) {
        let audio = MobileAudioReviewViewModel.shared
        guard audio.voiceListen?.sourceID == narration.sourceID else { return }
        // Its place is kept, and a narration still being made stops there:
        // nothing more is billed, and asking for it again carries on.
        if audio.isPlaying { audio.togglePlayback() }
        audio.stopTextToSpeechGeneration(sourceID: narration.sourceID)
        audio.voiceListen = nil
        startVoiceAgent(returningFrom: narration)
    }

    private func makeVoiceTemplate() -> CPVoiceControlTemplate {
        // CarPlay owns this layout, but CPVoiceControlState accepts animated
        // images. Keep active conversation states wordless and show the
        // ForeverLM mark, not an anonymous orb (product owner, 2026-11-11: "is
        // it possible to have the foreverlm logo and not the dot").
        let listening = CPVoiceControlState(
            identifier: "listening",
            titleVariants: nil,
            image: CarPlayVoiceMarkRenderer.image(for: .listening),
            repeats: true
        )
        let thinking = CPVoiceControlState(
            identifier: "thinking",
            titleVariants: nil,
            image: CarPlayVoiceMarkRenderer.image(for: .thinking),
            repeats: true
        )
        let speaking = CPVoiceControlState(
            identifier: "speaking",
            titleVariants: nil,
            image: CarPlayVoiceMarkRenderer.image(for: .speaking),
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
        needsOwnKey: Bool
    ) -> String {
        if needsOwnKey { return "sign-in" }
        switch statusText {
        case "Thinking": return "thinking"
        case "Speaking": return "speaking"
        default:
            return phase == .failed ? "unavailable" : "listening"
        }
    }
}

/// What the car shows: the voice conversation, or the narration the assistant
/// handed the audio to (`listen_to_source`). A narration is on screen only
/// while no conversation runs; one that ended, by playing through or by
/// failing, sends the learner back to the assistant, which says so.
enum CarPlayVoiceScreen: Equatable {
    case conversation
    case narration(title: String, isPlaying: Bool)
    case backToAssistant(RealtimeVoiceAssistant.NarrationReturn)

    static func resolve(conversationIsIdle: Bool, listen: MobileVoiceListen?, isPlaying: Bool) -> CarPlayVoiceScreen {
        guard conversationIsIdle, let listen else { return .conversation }
        switch listen.ended {
        case nil:
            return .narration(title: listen.title, isPlaying: isPlaying)
        case .finished:
            return .backToAssistant(.init(sourceID: listen.sourceID, title: listen.title, outcome: .finished))
        case .failed(let reason):
            return .backToAssistant(.init(sourceID: listen.sourceID, title: listen.title, outcome: .failed(reason)))
        }
    }
}

/// The ForeverLM mark for the system-owned CarPlay voice template, moving a
/// little differently in each state so a glance tells listening from thinking
/// from speaking: listening breathes slowly, thinking runs a band of light
/// across the loops, speaking pulses. It draws the shipped `BrandMark` artwork
/// and never a new mark (the brand rule in `ForeverLMMark`); only its size and
/// the light on it move. Frames are made once when CarPlay connects and CarPlay
/// plays them, so there is no display link or polling loop.
private enum CarPlayVoiceMarkRenderer {
    enum Activity {
        case listening
        case thinking
        case speaking
    }

    /// `CPVoiceControlState` images may be at most 150 by 150 points.
    private static let canvas = CGSize(width: 150, height: 150)
    /// The mark's width at rest: the speaking pulse grows it 6%, which still
    /// clears the canvas edge.
    private static let restingWidth: CGFloat = 136
    private static let frameCount = 16

    static func image(for activity: Activity) -> UIImage? {
        guard let mark = UIImage(named: "BrandMark") else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let frames = (0..<frameCount).map { index in
            renderer.image { rendererContext in
                draw(
                    mark,
                    activity: activity,
                    progress: CGFloat(index) / CGFloat(frameCount),
                    in: rendererContext.cgContext
                )
            }
        }
        return UIImage.animatedImage(with: frames, duration: duration(for: activity))
    }

    /// One cycle each, inside CarPlay's 0.3 to 5 second bounds.
    private static func duration(for activity: Activity) -> TimeInterval {
        switch activity {
        case .listening: return 2.4
        case .thinking: return 1.6
        case .speaking: return 0.9
        }
    }

    /// `progress` runs from 0 up to (not including) 1 over one cycle.
    private static func draw(
        _ mark: UIImage,
        activity: Activity,
        progress: CGFloat,
        in context: CGContext
    ) {
        let angle = progress * 2 * .pi
        let scale: CGFloat
        switch activity {
        case .listening: scale = 1 + sin(angle) * 0.025
        case .thinking: scale = 1
        // Two beats a cycle, from rest up to 6% larger and back.
        case .speaking: scale = 1 + (1 - cos(angle * 2)) / 2 * 0.06
        }

        let width = restingWidth * scale
        let height = width * mark.size.height / mark.size.width
        let markRect = CGRect(
            x: (canvas.width - width) / 2,
            y: (canvas.height - height) / 2,
            width: width,
            height: height
        )
        mark.draw(in: markRect)

        if activity == .thinking {
            drawSweep(across: markRect, progress: progress, in: context)
        }
    }

    /// A soft band of light crossing the mark from left to right. It starts
    /// wholly left of the mark and ends wholly right of it, so the loop has no
    /// visible seam. `.sourceAtop` lays the light on the artwork's own pixels
    /// only, so the silhouette never changes.
    private static func drawSweep(across markRect: CGRect, progress: CGFloat, in context: CGContext) {
        let band = markRect.width * 0.38
        let leadingEdge = markRect.minX - band + (markRect.width + band) * progress
        guard let light = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(white: 1, alpha: 0).cgColor,
                UIColor(white: 1, alpha: 0.55).cgColor,
                UIColor(white: 1, alpha: 0).cgColor,
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) else { return }

        context.saveGState()
        context.setBlendMode(.sourceAtop)
        context.drawLinearGradient(
            light,
            start: CGPoint(x: leadingEdge, y: markRect.midY),
            end: CGPoint(x: leadingEdge + band, y: markRect.midY),
            options: []
        )
        context.restoreGState()
    }
}

#if DEBUG
/// `-foreverlm-uitest-carplay` (with `-foreverlm-uitest-app`): the car's screen plays one spoken exchange
/// of a voice review on the real template, in a loop, with no voice session, so the Simulator's CarPlay
/// window can be filmed for the website without signing in or spending anything. The learner asks, the
/// tutor thinks and asks a card, the learner answers, the tutor thinks and grades it. The loop starts
/// and ends listening, so a clip cut at its length loops cleanly.
enum CarPlayVoiceScript {
    static let launchArgument = "-foreverlm-uitest-carplay"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Seconds from the start of the loop, and the state shown from then on.
    static let beats: [(at: Double, state: String)] = [
        (0, "listening"),
        (3.0, "thinking"),
        (4.4, "speaking"),
        (8.6, "listening"),
        (10.4, "thinking"),
        (11.4, "speaking"),
    ]
    static let loop: Double = 14

    @MainActor
    static func play(on template: CPVoiceControlTemplate) -> Task<Void, Never> {
        Task { @MainActor in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let start = clock.now
                for beat in beats {
                    try? await clock.sleep(until: start + .milliseconds(Int(beat.at * 1000)))
                    if Task.isCancelled { return }
                    template.activateVoiceControlState(withIdentifier: beat.state)
                }
                try? await clock.sleep(until: start + .milliseconds(Int(loop * 1000)))
            }
        }
    }
}
#endif
