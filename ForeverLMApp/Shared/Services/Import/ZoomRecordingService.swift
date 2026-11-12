import Foundation
import OSLog

/// Fetches transcripts for one-off Zoom cloud-recording share links
/// (`https://<sub>.zoom.us/rec/play/<id>` or `/rec/share/<id>`).
///
/// Protocol (verified against Zoom's recording web player, June 2026):
/// 1. GET the share/play page — this sets the `_zm_ssid` session cookies and
///    embeds a `window.__data__` JS object holding `meetingId` (share pages)
///    or `fileId` (play pages).
/// 2. Share pages: GET `/nws/recording/1.0/play/share-info/<meetingId>` which
///    returns a redirect path to the play page; follow it and parse `fileId`.
/// 3. GET `/nws/recording/1.0/play/info/<fileId>` — returns `topic`,
///    `viewMp4Url`, and (when the host enabled them) `transcriptUrl`/`ccUrl`
///    pointing at WebVTT files.
/// 4. Passcode-protected recordings answer both info calls with
///    `componentName: "need-password"`. A form-encoded POST to
///    `/nws/recording/1.0/validate-meeting-passwd` (meeting-level passcode) or
///    `/validate-passwd` (file-level) with `id`, `passwd`, `action`,
///    `recaptcha=""` marks the session cookies as validated.
///
/// The only transcript this reads is Zoom's own — the VTT transcript, or the
/// closed captions when that is what the recording carries. It never downloads
/// the recording. Fetching the VTT still needs the session cookies plus a
/// `Referer` header on the recording's zoom.us host.
///
/// Zoom writes its transcript after the recording itself is ready, and the
/// "Meeting assets are ready" notice goes out before it lands, so a fetch made
/// the moment the notice arrives often finds `viewMp4Url` and no
/// `transcriptUrl`. That is `ZoomRecordingError.transcriptNotReady`, not a
/// failure: the caller keeps the session waiting and asks again later
/// (`StudioViewModel.fetchZoomTranscript`).
///
/// There is no fallback that downloads the MP4 and pays for STT when
/// Zoom has published no transcript. It cannot work: a share link hands
/// an anonymous download a few seconds of the recording (5.1 s and 6.6 s of
/// audio from 15-minute standups), so every standup would end in "Transcription
/// produced no text" — and removal is a tombstone, so such a standup can never
/// be re-filed. The product owner, twice
/// (2026-09-12: "no need to also have the recordings"; 2026-09-15: "we never
/// really need to upload the recording, just the transcript is ok"). Waiting
/// for Zoom is the whole strategy; do not reintroduce a media route.
actor ZoomRecordingService {
    static let shared = ZoomRecordingService()

    private let logger = Logger(subsystem: "ForeverLM", category: "ZoomRecording")

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// One cookie-holding session for the actor's lifetime so a validated
    /// passcode keeps working for retries and later refetches.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.timeoutIntervalForRequest = 60
        // Recordings can be multi-GB; give downloads room to finish.
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    enum ZoomRecordingError: LocalizedError {
        case invalidURL
        case passcodeRequired
        case wrongPasscode(String)
        case pageUnavailable(String)
        case apiError(String)
        case emptyTranscript
        /// Zoom has published the recording but not its transcript (or the
        /// share does not carry one). The string names the fields Zoom did
        /// return, so a session that never gets one can be diagnosed.
        case transcriptNotReady(assets: String)
        /// Zoom answers the share with error 3301, "This recording does not
        /// exist": deleted from the account, or expired. Asking again will
        /// not change it.
        case recordingGone(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Not a Zoom recording link (expected zoom.us/rec/play or /rec/share)."
            case .passcodeRequired:
                return "This Zoom recording requires a passcode."
            case .wrongPasscode(let m):
                return "Zoom rejected the passcode: \(m)"
            case .pageUnavailable(let m):
                return "Could not load the Zoom recording page: \(m)"
            case .apiError(let m):
                return "Zoom recording API error: \(m)"
            case .emptyTranscript:
                return "The Zoom recording produced no transcript text."
            case .transcriptNotReady(let assets):
                return "Zoom has not published this recording's transcript yet\(assets.isEmpty ? "" : " (Zoom offered: \(assets))")."
            case .recordingGone(let m):
                return "Zoom no longer has this recording: \(m)"
            }
        }

        /// Whether waiting and asking Zoom again can change the answer.
        var isWorthRetrying: Bool {
            switch self {
            case .transcriptNotReady, .emptyTranscript, .pageUnavailable, .apiError:
                return true
            case .invalidURL, .passcodeRequired, .wrongPasscode, .recordingGone:
                return false
            }
        }
    }

    // MARK: - URL detection

    /// A one-off Zoom cloud-recording share or play link.
    nonisolated static func isZoomRecordingURL(_ urlString: String) -> Bool {
        ForeverLMCore.isZoomRecordingURL(urlString)
    }

    // MARK: - Public entry point

    struct RecordingTranscript {
        let transcript: String
        let topic: String?
    }

    /// Resolve a share/play URL and return Zoom's transcript for it.
    /// `passcode` is only needed for recordings that throw
    /// `ZoomRecordingError.passcodeRequired` without one. A recording Zoom has
    /// not transcribed yet throws `transcriptNotReady`, which the caller
    /// treats as "ask again later" rather than as a failure.
    func fetchTranscript(from urlString: String, passcode: String? = nil) async throws -> RecordingTranscript {
        let info = try await resolvePlayInfo(from: urlString, passcode: passcode)
        let topic = info.result.displayTopic
        let assets = Self.assetSummary(fieldNames: info.fieldNames)

        if let vttURL = info.result.transcriptFileURL(relativeTo: info.baseURL) {
            let vtt = try await fetchText(vttURL, referer: info.baseURL)
            let text = Self.plainTextFromVTT(vtt)
            if !text.isEmpty {
                return RecordingTranscript(transcript: text, topic: topic)
            }
            logger.info("Zoom VTT was empty (play info: \(assets, privacy: .public))")
        } else {
            logger.info("Zoom play info carries no transcript yet (fields: \(assets, privacy: .public))")
        }

        throw ZoomRecordingError.transcriptNotReady(assets: assets)
    }

    // MARK: - Play-info resolution

    private struct ResolvedInfo {
        let baseURL: URL
        let result: PlayResult
        /// The names of the fields Zoom's play-info answer carried a value
        /// for, so a missing transcript can be told apart from a changed API.
        let fieldNames: [String]
    }

    private func resolvePlayInfo(from urlString: String, passcode: String?) async throws -> ResolvedInfo {
        guard Self.isZoomRecordingURL(urlString),
              let pageURL = URL(string: urlString),
              let host = pageURL.host,
              let baseURL = URL(string: "https://\(host)") else {
            throw ZoomRecordingError.invalidURL
        }

        var playPageURL = pageURL
        if pageURL.path.lowercased().contains("share") {
            let sharePage = try await fetchText(pageURL, referer: nil)
            let shareData = Self.parseWindowData(sharePage)
            guard let meetingID = shareData["meetingId"], !meetingID.isEmpty else {
                throw ZoomRecordingError.pageUnavailable("no meeting id on the share page")
            }
            let shareInfo = try await playAPI(
                path: "play/share-info/\(meetingID)", baseURL: baseURL, passcode: passcode
            )
            guard let redirect = shareInfo.redirectUrl,
                  redirect.contains("/rec/play/") || redirect.contains("/recording/play/"),
                  let resolved = URL(string: redirect, relativeTo: baseURL) else {
                throw ZoomRecordingError.apiError("share link did not resolve to a playable recording")
            }
            playPageURL = resolved
        }

        let playPage = try await fetchText(playPageURL, referer: baseURL)
        let playData = Self.parseWindowData(playPage)
        guard let fileID = playData["fileId"], !fileID.isEmpty else {
            throw ZoomRecordingError.pageUnavailable("no file id on the play page")
        }
        let (result, fieldNames) = try await playAPIWithFieldNames(path: "play/info/\(fileID)", baseURL: baseURL, passcode: passcode)
        return ResolvedInfo(baseURL: baseURL, result: result, fieldNames: fieldNames)
    }

    /// Call a `/nws/recording/1.0/...` endpoint; when Zoom answers with the
    /// need-password component, validate the passcode once and retry.
    private func playAPI(path: String, baseURL: URL, passcode: String?) async throws -> PlayResult {
        try await playAPIWithFieldNames(path: path, baseURL: baseURL, passcode: passcode).result
    }

    private func playAPIWithFieldNames(path: String, baseURL: URL, passcode: String?) async throws -> (result: PlayResult, fieldNames: [String]) {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "/nws/recording/1.0/\(escaped)?canPlayFromShare=true&continueMode=true&componentName=rec-play", relativeTo: baseURL) else {
            throw ZoomRecordingError.invalidURL
        }

        var envelope = try await fetchPlayEnvelope(url, baseURL: baseURL)
        if envelope.result.needsPasscode {
            guard let passcode, !passcode.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ZoomRecordingError.passcodeRequired
            }
            try await validatePasscode(passcode, gate: envelope.result, baseURL: baseURL)
            envelope = try await fetchPlayEnvelope(url, baseURL: baseURL)
            if envelope.result.needsPasscode {
                throw ZoomRecordingError.wrongPasscode("passcode accepted but access was still denied")
            }
        }
        return envelope
    }

    private func fetchPlayEnvelope(_ url: URL, baseURL: URL) async throws -> (result: PlayResult, fieldNames: [String]) {
        var request = URLRequest(url: url)
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ZoomRecordingError.apiError("HTTP \(http.statusCode) from \(url.path)")
        }
        let envelope: PlayEnvelope
        do {
            envelope = try JSONDecoder().decode(PlayEnvelope.self, from: data)
        } catch {
            throw ZoomRecordingError.apiError("unexpected response from \(url.path)")
        }
        guard envelope.status, let result = envelope.result else {
            throw Self.rejection(code: envelope.errorCode, message: envelope.errorMessage)
        }
        return (result, Self.populatedFieldNames(inPlayInfo: data))
    }

    /// A rejected play-info answer as the error it means: 3301 ("This
    /// recording does not exist.") is the recording gone for good, anything
    /// else a call worth repeating later.
    nonisolated static func rejection(code: Int?, message: String?) -> ZoomRecordingError {
        let text = message ?? "request rejected (\(code ?? 0))"
        if code == 3301 || text.localizedCaseInsensitiveContains("does not exist") {
            return .recordingGone(text)
        }
        return .apiError(text)
    }

    /// The top-level `result` fields Zoom's play-info answer gave a value to,
    /// sorted. Diagnostic only: the typed decode above is what the code
    /// reads, this is what a log line or an error message shows so that a
    /// transcript Zoom moved to a field this code does not know can be found.
    nonisolated static func populatedFieldNames(inPlayInfo data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return [] }
        return result.compactMap { key, value -> String? in
            if value is NSNull { return nil }
            if let string = value as? String, string.isEmpty { return nil }
            return key
        }.sorted()
    }

    /// "viewMp4Url, shareMp4Url" — the asset-bearing fields among
    /// `fieldNames`, for the not-ready error and the log. Fields that describe
    /// the recording rather than carry an asset are left out.
    nonisolated static func assetSummary(fieldNames: [String]) -> String {
        fieldNames
            .filter { name in
                let lower = name.lowercased()
                return lower.hasSuffix("url") || lower.contains("transcript") || lower.contains("caption") || lower.hasPrefix("cc")
            }
            .joined(separator: ", ")
    }

    private func validatePasscode(_ passcode: String, gate: PlayResult, baseURL: URL) async throws {
        let isMeetingLevel = (gate.useWhichPasswd ?? "meeting") == "meeting"
        let endpoint = isMeetingLevel ? "validate-meeting-passwd" : "validate-passwd"
        guard let id = isMeetingLevel ? gate.meetingId : gate.fileId, !id.isEmpty,
              let url = URL(string: "/nws/recording/1.0/\(endpoint)", relativeTo: baseURL) else {
            throw ZoomRecordingError.apiError("passcode gate did not include a validation id")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Self.formEncode([
            ("id", id),
            ("passwd", passcode),
            ("action", gate.action ?? ""),
            ("recaptcha", ""),
        ]).data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        struct Validation: Decodable {
            let status: Bool
            let errorMessage: String?
        }
        guard let validation = try? JSONDecoder().decode(Validation.self, from: data) else {
            throw ZoomRecordingError.apiError("unexpected passcode validation response")
        }
        guard validation.status else {
            throw ZoomRecordingError.wrongPasscode(validation.errorMessage ?? "wrong passcode")
        }
        logger.info("Zoom passcode validated")
    }

    // MARK: - Downloads

    private func fetchText(_ url: URL, referer: URL?) async throws -> String {
        var request = URLRequest(url: url)
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ZoomRecordingError.pageUnavailable("HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ZoomRecordingError.pageUnavailable("response was not text")
        }
        return text
    }

    // MARK: - Page/data parsing

    /// Extract the `window.__data__ = {...}` JS object from a recording page and
    /// return its string-valued fields. The blob is JavaScript, not JSON: keys
    /// are unquoted and values use single or double quotes.
    nonisolated static func parseWindowData(_ html: String) -> [String: String] {
        guard let marker = html.range(of: #"window\.__data__\s*=\s*\{"#, options: .regularExpression) else {
            return [:]
        }
        // Brace-match from the opening "{" (last character of the marker match).
        let start = html.index(before: marker.upperBound)
        var depth = 0
        var end = start
        var index = start
        while index < html.endIndex {
            let char = html[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    end = html.index(after: index)
                    break
                }
            }
            index = html.index(after: index)
        }
        guard depth == 0, end > start else { return [:] }
        let blob = String(html[start..<end])

        var fields: [String: String] = [:]
        let pattern = #"(\w+)\s*:\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(blob.startIndex..., in: blob)
        regex.enumerateMatches(in: blob, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: blob) else { return }
            let valueRange = Range(match.range(at: 2), in: blob) ?? Range(match.range(at: 3), in: blob)
            guard let valueRange else { return }
            let key = String(blob[keyRange])
            let value = String(blob[valueRange])
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    /// Convert a WebVTT transcript/caption file to readable plain text with
    /// `[h:mm:ss]` markers. Zoom transcript cues already carry speaker names
    /// ("Jane Doe: …"), which are preserved verbatim.
    nonisolated static func plainTextFromVTT(_ vtt: String) -> String {
        let normalized = vtt.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        var previousText = ""

        for block in normalized.components(separatedBy: "\n\n") {
            let blockLines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = blockLines.firstIndex(where: { $0.contains("-->") }) else { continue }

            let text = blockLines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != previousText else { continue }
            previousText = text

            let rawStamp = blockLines[timingIndex]
                .components(separatedBy: "-->")[0]
                .trimmingCharacters(in: .whitespaces)
            lines.append("[\(displayStamp(fromVTTTime: rawStamp))] \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// "00:01:02.840" → "1:02"; "01:02:03.000" → "1:02:03".
    nonisolated static func displayStamp(fromVTTTime raw: String) -> String {
        let clock = raw.components(separatedBy: ".")[0]
        var parts = clock.split(separator: ":").map(String.init)
        if parts.count == 2 { parts.insert("0", at: 0) }
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) else {
            return clock
        }
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    nonisolated static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    // MARK: - API payloads

    struct PlayEnvelope: Decodable {
        let status: Bool
        let errorCode: Int?
        let errorMessage: String?
        let result: PlayResult?
    }

    /// Union of the fields Zoom returns from share-info/play-info — both the
    /// passcode gate shape and the actual recording shape.
    struct PlayResult: Decodable {
        // Passcode gate
        let componentName: String?
        let useWhichPasswd: String?
        let meetingId: String?
        let action: String?
        let redirectUrl: String?
        // Recording info
        let fileId: String?
        let topic: String?
        /// Decoded only so `assetSummary` can say the recording itself is
        /// there and the transcript is not. Nothing downloads these.
        let viewMp4Url: String?
        let transcriptUrl: String?
        let ccUrl: String?
        let meet: Meet?

        struct Meet: Decodable {
            let topic: String?
        }

        var needsPasscode: Bool { componentName == "need-password" }

        var displayTopic: String? {
            let candidate = [topic, meet?.topic]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return candidate
        }

        func transcriptFileURL(relativeTo base: URL) -> URL? {
            for candidate in [transcriptUrl, ccUrl] {
                if let candidate, !candidate.isEmpty, let url = URL(string: candidate, relativeTo: base) {
                    return url
                }
            }
            return nil
        }
    }
}
