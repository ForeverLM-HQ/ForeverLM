import Foundation
import Observation

/// Publisher checks (Cloudflare, a CAPTCHA, an MFA prompt, or a sign-in wall)
/// that a background download ran into and cannot clear on its own.
///
/// PDF downloads run headless: the WebView that fetches a paper is never put on
/// screen, so a batch of papers can resolve while the user works. Only when a
/// page genuinely needs a human does the downloader park a request here — the
/// window is built lazily, when the user asks for it from the Studio banner,
/// instead of being thrown in front of whatever they were doing.
///
/// One shared registry rather than view-model state: the downloaders are plain
/// services reached from the Studio pipeline, batch enrichment, and MCP alike.
@MainActor
@Observable
final class WebVerificationRequests {
    static let shared = WebVerificationRequests()

    struct Request: Identifiable {
        let id = UUID()
        /// Banner sentence, e.g. "ScienceDirect needs a quick verification".
        let message: String
        /// The source being downloaded, when the caller knows it.
        let detail: String?
        /// Builds and shows the browser window. Runs only if the user opts in.
        let open: () -> Void
        /// Abandons the download behind the request.
        let skip: () -> Void
    }

    private(set) var pending: [Request] = []

    /// The request a banner should render. Newest wins: a later check is the one
    /// blocking work right now, and clearing it usually clears the earlier ones
    /// too (the `cf_clearance` cookie is shared across every WebView).
    ///
    /// Nil while banners are held (`holdBanners`): requests keep waiting in
    /// `pending`, they just are not offered.
    var latest: Request? { isHeld ? nil : pending.last }

    /// True while the banner is held back. Observable, so the Studio banner
    /// reappears by itself when the hold ends.
    private(set) var isHeld = false
    private var holdTask: Task<Void, Never>?

    /// Keeps the banner off screen for `duration`. Setup's paper imports run
    /// into publisher checks, and the banner they raise must not greet the
    /// learner the moment setup finishes (product owner, 2026-11-21: "when I
    /// finished onboarding and don't yet want to see these notifications").
    func holdBanners(for duration: Duration) {
        isHeld = true
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.isHeld = false
        }
    }

    @discardableResult
    func request(
        message: String,
        detail: String?,
        open: @escaping () -> Void,
        skip: @escaping () -> Void
    ) -> UUID {
        let request = Request(message: message, detail: detail, open: open, skip: skip)
        pending.append(request)
        return request.id
    }

    /// Withdraws a request without touching the work behind it — the check
    /// cleared on its own, or the download finished or failed anyway.
    func withdraw(_ id: UUID?) {
        guard let id else { return }
        pending.removeAll { $0.id == id }
    }

    func open(_ id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        request.open()
    }

    func skip(_ id: UUID) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        request.skip()
    }
}
