import AppKit
import Foundation
import OSLog
import UserNotifications

/// A publisher check (Cloudflare, a CAPTCHA, an MFA prompt, or a sign-in wall)
/// that a background paper download ran into and cannot clear on its own,
/// said as a macOS notification.
///
/// PDF downloads run headless, so a batch of papers resolves while the learner
/// works. When a page genuinely needs a human, the download gives up and the
/// paper waits in Papers Needing Attention, as any paper without its PDF does;
/// this notification says which paper and why. Clicking it opens the paper's
/// own page in a Browser tab, never a window of its own (product owner,
/// 2026-11-26: "these publisher checks can go in notifications rather than
/// these popups? and just use the browser"). The Browser's Library profile is
/// the jar paper fetching uses, so the check passed there carries its cookie
/// into later downloads, and a PDF downloaded on the paper's page attaches to
/// the paper (`WebPagePolicy.paperNeedingPDF`).
@MainActor
enum PublisherCheckNotifications {
    /// One notification per paper page, so a second check for the same paper
    /// replaces the first rather than stacking.
    static let identifierPrefix = "com.foreverlm.publisherCheck."
    /// macOS groups every publisher check under one stack.
    static let threadIdentifier = "com.foreverlm.publisherCheck"
    /// The page a click opens in the Browser.
    static let pageURLKey = "pageURL"

    private static let logger = Logger(subsystem: "ForeverLM", category: "PublisherCheck")
    private static var heldUntil: Date?

    /// Keeps checks quiet for `duration`. Setup's paper imports run into
    /// publisher checks, and what they raise must not greet the learner the
    /// moment setup finishes (product owner, 2026-11-21: "when I finished
    /// onboarding and don't yet want to see these notifications"). A paper
    /// held back still waits in Papers Needing Attention.
    static func hold(for duration: Duration, now: Date = Date()) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        heldUntil = now.addingTimeInterval(seconds)
    }

    static func isHeld(now: Date = Date()) -> Bool {
        guard let heldUntil else { return false }
        return now < heldUntil
    }

    static func identifier(for pageURL: URL) -> String {
        identifierPrefix + SourceDiscovery.normalizedURL(pageURL.absoluteString)
    }

    static func title(publisher: String) -> String {
        "\(publisher) wants to check you're human"
    }

    static func body(paperTitle: String?) -> String {
        let paper = paperTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = paper.isEmpty ? "A paper" : paper
        return "\(subject) is waiting for its PDF. Click to open its page in the Browser."
    }

    /// Says that `pageURL`'s paper is stuck behind a publisher check. A Mac
    /// that refuses notifications, a hold, or screen record mode keeps it
    /// quiet; the paper waits in Papers Needing Attention either way.
    static func post(publisher: String, paperTitle: String?, pageURL: URL) {
        guard !isHeld() else { return }
        // A warning label is never filmed.
        guard AppModelBridge.studio?.isScreenRecordModeActive != true else { return }
        let content = UNMutableNotificationContent()
        content.title = title(publisher: publisher)
        content.body = body(paperTitle: paperTitle)
        content.threadIdentifier = threadIdentifier
        content.userInfo = [pageURLKey: pageURL.absoluteString]
        let request = UNNotificationRequest(
            identifier: identifier(for: pageURL),
            content: content,
            trigger: nil
        )
        Task {
            switch await NotificationPermission.current() {
            case .allowed:
                break
            case .notAsked:
                guard await NotificationPermission.request() == .allowed else { return }
            case .refused:
                logger.info("Notifications are refused on this Mac; the paper waits in Papers Needing Attention")
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Could not post the publisher check: \(error.localizedDescription)")
            }
        }
    }

    /// The click: the paper's page in a Browser tab of the frontmost window.
    static func open(pageURL raw: String) {
        guard let url = URL(string: raw) else { return }
        NSApp.activate()
        AppModelBridge.studio?.openInBrowser(url)
    }
}
