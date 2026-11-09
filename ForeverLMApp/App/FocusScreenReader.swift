import AppKit
import OSLog
import ScreenCaptureKit
import Vision

/// Read the Window Too, for Nudge Me Back on Track (product owner,
/// 2026-11-08: "can it monitor my mac screen?", then "Yes, add screen
/// reading"): the words in the window in front, read on this Mac, so a
/// window whose title says nothing ("Spotify Premium", "Calendar", a Slack
/// channel) is judged by what it shows.
///
/// One window, the frontmost of the app in front — never the whole screen —
/// captured once per new thing in front (`FocusJudge` asks only when it has
/// not judged that window under the goal), its words recognised with Vision,
/// handed to the on-device judge and dropped. No image or text is kept,
/// logged or sent anywhere. Password managers are never read.
///
/// Needs Screen Recording, which only the learner can grant (System Settings
/// › Privacy & Security › Screen & System Audio Recording).
///
/// Measured 2026-11-08 on ten windows whose titles say little, three runs
/// each: titles alone 23 of 30, with the window's words 25 of 30 — a Slack
/// channel about the paper told from one about the weekend, a family chat
/// caught; a music app and the Calendar still judged distractions now and then.
enum FocusScreenReader {
    /// macOS lets ForeverLM capture the screen. Cheap: no prompt.
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's Screen Recording prompt, once; after that macOS only
    /// answers.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    /// Apps whose windows show secrets in the clear: never captured, judged
    /// by their title alone.
    static let neverReadBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop", "org.keepassxc.keepassxc",
    ]

    /// The longest side the window is captured at: text stays readable,
    /// recognition stays quick.
    static let maximumSide: CGFloat = 1600
    /// The most words kept: the judge reads `FocusJudge.screenTextLimit`.
    static let maximumCharacters = 2_000

    /// The words in `pid`'s frontmost on-screen window, nil when there is no
    /// such window or it could not be captured (said in the log).
    static func words(inFrontWindowOf pid: pid_t) async -> String? {
        guard isAllowed, let windowID = frontWindowID(of: pid) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = min(1, maximumSide / max(window.frame.width, window.frame.height, 1))
            let pointScale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int(window.frame.width * pointScale * scale))
            configuration.height = max(1, Int(window.frame.height * pointScale * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let text = recognizedText(in: image)
            return text.isEmpty ? nil : String(text.prefix(maximumCharacters))
        } catch {
            FocusScreenReaderLog.logger.error("Could not read the window in front: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The window `pid` has in front: the first of its normal-layer windows
    /// in the window server's front-to-back order.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    /// The window's words, read with Vision's accurate recogniser. The fast
    /// one garbled a Reader window past use ("miDNA Mui•tlon• Oocytw" for
    /// "mtDNA Mutations … Oocytes", 2026-11-08); the accurate one read it
    /// cleanly in half a second, after a one-time model load of about half a
    /// minute the first time in a launch (off the main actor).
    static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            FocusScreenReaderLog.logger.error("Could not recognise the window's words: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }
}

private enum FocusScreenReaderLog {
    static let logger = Logger(subsystem: "ForeverLM", category: "FocusWatch")
}
