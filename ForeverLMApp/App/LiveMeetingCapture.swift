import AppKit
import CoreImage
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import Vision

enum LiveMeetingLog {
    static let capture = Logger(subsystem: "com.foreverlm", category: "LiveMeeting")
}

enum LiveMeetingError: LocalizedError, Equatable {
    case needsNewerMacOS
    case screenRecordingDenied
    case noDisplay
    case languageUnsupported(String)
    case speechModelUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .needsNewerMacOS:
            return "A live meeting needs macOS 26 or later."
        case .screenRecordingDenied:
            return "Allow ForeverLM under Screen & System Audio Recording in System Settings, then start again."
        case .noDisplay:
            return "No display to record the call's sound from."
        case .languageUnsupported(let identifier):
            return "This Mac's speech model doesn't support \(identifier)."
        case .speechModelUnavailable:
            return "This Mac's speech model isn't available."
        case .captureFailed(let message):
            return message
        }
    }
}

/// Records a call as it happens: the sound the call plays and the learner's
/// microphone, each into its own transcriber, and optionally one window the
/// learner picks, from which each new slide is kept with the words on it.
///
/// Everything runs on this Mac. The call's sound comes from ScreenCaptureKit
/// over the whole display with ForeverLM's own sound left out, so any meeting
/// app works (a browser tab, Zoom, Teams) and nobody installs anything.
@available(macOS 26.0, *)
final class LiveMeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias LineHandler = @Sendable (LiveMeetingVoice, LiveMeetingTranscriber.Update) -> Void
    typealias SlideHandler = @Sendable (_ number: Int, _ shownAt: TimeInterval, _ imageURL: URL, _ text: String) -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    private let audioQueue = DispatchQueue(label: "com.foreverlm.live-meeting.audio", qos: .userInitiated)
    private let slideQueue = DispatchQueue(label: "com.foreverlm.live-meeting.slides", qos: .utility)
    private let slidesFolder: URL
    private let onSlide: SlideHandler
    private let onFailure: FailureHandler

    private var audioStream: SCStream?
    private var slideStream: SCStream?
    private var transcribers: [LiveMeetingVoice: LiveMeetingTranscriber] = [:]
    /// Host-clock seconds at the start of the meeting; buffers are timed from it.
    private let startHostSeconds: TimeInterval

    // Touched only on the slide queue.
    private var detector = LiveMeetingSlideDetector()
    private var slideCount = 0
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init(slidesFolder: URL, onSlide: @escaping SlideHandler, onFailure: @escaping FailureHandler) {
        self.slidesFolder = slidesFolder
        self.onSlide = onSlide
        self.onFailure = onFailure
        self.startHostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        super.init()
    }

    /// Starts recording the call's sound and the microphone. Throws before
    /// anything runs when permission is missing or the speech model cannot load.
    static func start(
        locale: Locale,
        slidesFolder: URL,
        onLine: @escaping LineHandler,
        onSlide: @escaping SlideHandler,
        onFailure: @escaping FailureHandler
    ) async throws -> LiveMeetingCapture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw LiveMeetingError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw LiveMeetingError.noDisplay }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        let capture = LiveMeetingCapture(slidesFolder: slidesFolder, onSlide: onSlide, onFailure: onFailure)
        for voice in LiveMeetingVoice.allCases {
            capture.transcribers[voice] = try await LiveMeetingTranscriber.prepare(voice: voice, locale: locale, onUpdate: onLine)
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // The audio stream needs a video size but draws nothing from it.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: capture)
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.audioQueue)
        try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: capture.audioQueue)
        do {
            try await stream.startCapture()
        } catch {
            for transcriber in capture.transcribers.values { await transcriber.finish() }
            throw LiveMeetingError.captureFailed(error.localizedDescription)
        }
        capture.audioStream = stream
        return capture
    }

    /// Starts keeping slides from the window or display in `filter`, the one the
    /// learner picked in the system's sharing picker. Replaces an earlier pick.
    func watchSlides(filter: SCContentFilter) async throws {
        if let slideStream {
            try? await slideStream.stopCapture()
            self.slideStream = nil
        }
        slideQueue.sync { detector = LiveMeetingSlideDetector() }
        let configuration = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = min(1, 1_920 / max(size.width * CGFloat(filter.pointPixelScale), 1))
        configuration.width = max(2, Int(size.width * CGFloat(filter.pointPixelScale) * scale))
        configuration.height = max(2, Int(size.height * CGFloat(filter.pointPixelScale) * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: slideQueue)
        try await stream.startCapture()
        slideStream = stream
    }

    var isWatchingSlides: Bool { slideStream != nil }

    func stopWatchingSlides() async {
        guard let slideStream else { return }
        try? await slideStream.stopCapture()
        self.slideStream = nil
    }

    /// Stops recording and waits until the last words are transcribed.
    func stop() async {
        if let audioStream { try? await audioStream.stopCapture() }
        audioStream = nil
        await stopWatchingSlides()
        await withTaskGroup(of: Void.self) { group in
            for transcriber in transcribers.values {
                group.addTask { await transcriber.finish() }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio:
            transcribers[.them]?.append(sampleBuffer, meetingTime: meetingTime(of: sampleBuffer))
        case .microphone:
            transcribers[.me]?.append(sampleBuffer, meetingTime: meetingTime(of: sampleBuffer))
        case .screen:
            considerSlideFrame(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        LiveMeetingLog.capture.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        if stream === slideStream {
            slideStream = nil
            onFailure("Stopped watching slides: \(error.localizedDescription)")
        } else {
            onFailure(error.localizedDescription)
        }
    }

    private func meetingTime(of sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard presentation.isFinite else { return 0 }
        return max(0, presentation - startHostSeconds)
    }

    // MARK: Slides

    private func considerSlideFrame(_ sampleBuffer: CMSampleBuffer) {
        guard Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let fingerprint = fingerprint(of: image), detector.consider(fingerprint) else { return }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        slideCount += 1
        let number = slideCount
        let shownAt = meetingTime(of: sampleBuffer)
        // Named and written as a recording's captured slides are, so the
        // Reader and the chat's show_source_image read them the same way.
        let url = slidesFolder.appendingPathComponent(SlideFrameExtraction.imageFilename(index: number, timeSeconds: shownAt))
        do {
            try FileManager.default.createDirectory(at: slidesFolder, withIntermediateDirectories: true)
            try SlideFrameExtraction.writeJPEG(cgImage, to: url)
        } catch {
            LiveMeetingLog.capture.error("saving slide \(number): \(error.localizedDescription, privacy: .public)")
            onFailure("Couldn't save slide \(number): \(error.localizedDescription)")
            return
        }
        let text = Self.recognizedText(in: cgImage)
        onSlide(number, shownAt, url, text)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// The frame shrunk to the detector's grid, one grey byte a cell.
    private func fingerprint(of image: CIImage) -> [UInt8]? {
        let width = LiveMeetingSlideDetector.width
        let height = LiveMeetingSlideDetector.height
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
    }

    /// The words on a slide, read on this Mac with Vision.
    static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            LiveMeetingLog.capture.error("reading slide text: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
