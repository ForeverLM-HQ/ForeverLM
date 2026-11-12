import Foundation
import OSLog

/// Fetches YouTube video transcripts natively in Swift.
///
/// Uses the InnerTube API (ANDROID client) to get working caption URLs,
/// matching the approach used by youtube-transcript-api v1.x.
///
/// No external dependencies — just URLSession + JSON/XML parsing.
actor YouTubeTranscriptService {

    struct VideoMetadata: Equatable, Sendable {
        let title: String
        let channelName: String?
        let thumbnailURL: String?
    }

    /// One of YouTube's official chapter markers: the video's real table of
    /// contents, sourced from the creator's description timestamps or YouTube's
    /// own auto-chapters — not something inferred from the transcript.
    struct VideoChapter: Equatable, Sendable {
        /// Seconds from the start of the video where the chapter begins.
        let startSeconds: Double
        let title: String
    }

    private struct CaptionTrackCandidate {
        let url: URL
        let languageCode: String
        let kind: String
    }

    private struct CaptionSegment {
        let start: Double
        let duration: Double?
        let text: String

        var end: Double? {
            duration.map { start + $0 }
        }
    }

    static let shared = YouTubeTranscriptService()

    private let logger = Logger(subsystem: "com.foreverlm", category: "YouTubeTranscript")
    private let session: URLSession

    /// InnerTube ANDROID client context — returns caption URLs that work
    /// without browser cookies or IP-bound tokens.
    private static let innertubeContext: [String: Any] = [
        "client": [
            "clientName": "ANDROID",
            "clientVersion": "20.10.38",
        ]
    ]
    private static let innertubeIOSContext: [String: Any] = [
        "client": [
            "clientName": "IOS",
            "clientVersion": "20.10.4",
        ]
    ]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Well-known, static public InnerTube API key. YouTube embeds this same
    /// global key in every watch page, so we use it directly rather than
    /// scraping (and downloading) the watch page HTML on every request.
    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// Fetch the transcript for a YouTube video URL.
    /// Returns a tuple of (transcript text, video title).
    func fetchTranscript(from urlString: String) async throws -> (transcript: String, title: String?) {
        guard let videoId = Self.extractVideoId(from: urlString) else {
            logger.error("Failed to extract video ID from: \(urlString)")
            throw YouTubeTranscriptError.invalidURL
        }

        logger.info("Fetching transcript for video ID: \(videoId)")

        // The INNERTUBE_API_KEY is a static, global YouTube key — identical to the
        // one previously scraped from the watch page HTML — so we skip the
        // multi-megabyte watch page download entirely and go straight to the
        // InnerTube /player API. The ANDROID client needs no browser cookies, so
        // nothing on the critical path depends on the watch page.
        let apiKey = Self.fallbackAPIKey

        // Fetch the title (via the lightweight oEmbed endpoint first) concurrently
        // with the transcript so neither request blocks the other.
        async let titleTask: String? = fetchVideoTitle(videoId: videoId)

        let transcript = try await fetchCaptionTranscript(videoId: videoId, apiKey: apiKey)

        let title = await titleTask
        let wordCount = transcript.split(separator: " ").count
        logger.info("Successfully fetched transcript: \(wordCount) words")
        return (transcript, title)
    }

    /// A video's timed captions alone, as `fetchTranscript` returns them, for
    /// a caller that already knows the title: the check of a stored
    /// transcript against its captions (`YouTubeTranscriptCheckService`).
    func fetchCaptions(from urlString: String) async throws -> String {
        guard let videoId = Self.extractVideoId(from: urlString) else {
            throw YouTubeTranscriptError.invalidURL
        }
        return try await fetchCaptionTranscript(videoId: videoId, apiKey: Self.fallbackAPIKey)
    }

    private func fetchCaptionTranscript(videoId: String, apiKey: String) async throws -> String {
        // Step 1: Use InnerTube /player API to get caption tracks with working URLs
        let captionCandidates: [CaptionTrackCandidate]
        do {
            captionCandidates = try await fetchCaptionCandidatesViaInnerTube(
                videoId: videoId,
                apiKey: apiKey,
                context: Self.innertubeContext
            )
            if let first = captionCandidates.first {
                logger.info("Caption URL obtained: \(first.url.absoluteString.prefix(100))...")
            }
        } catch {
            logger.error("Step 1 failed (InnerTube caption URL): \(error)")
            throw error
        }

        // Step 2: Fetch and parse the caption XML
        let transcript: String
        do {
            transcript = try await fetchTranscriptWithFallbacks(
                videoId: videoId,
                apiKey: apiKey,
                primaryCandidates: captionCandidates
            )
        } catch {
            logger.error("Step 2 failed (caption XML fetch/parse): \(error)")
            throw error
        }
        return transcript
    }

    /// Fetch YouTube's official chapter markers for a video.
    ///
    /// Chapters live in the InnerTube `/next` endpoint's player-bar markers,
    /// which YouTube populates identically from creator-authored description
    /// timestamps and its own auto-generated chapters. The ANDROID client used
    /// for captions returns no markers, so this issues a separate WEB request.
    ///
    /// Best-effort by design: returns an empty array on any failure, or for a
    /// video that simply has no chapters. Callers read "no official chapters" as
    /// "leave whatever section headings the transcript already carries."
    func fetchChapters(videoId: String) async -> [VideoChapter] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/next?key=\(Self.fallbackAPIKey)&prettyPrint=false") else {
            return []
        }

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20260301.00.00",
                    "hl": "en",
                    "gl": "US",
                ]
            ],
            "videoId": videoId,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                return []
            }
            let chapters = Self.parseChapterMarkers(from: json)
            if !chapters.isEmpty {
                logger.info("Official YouTube chapters for \(videoId): \(chapters.count)")
            }
            return chapters
        } catch {
            logger.warning("Chapter fetch failed for \(videoId): \(error.localizedDescription)")
            return []
        }
    }

    /// Check if a URL is a supported YouTube URL.
    static func isYouTubeURL(_ urlString: String) -> Bool {
        YouTubeURLMetadata.isYouTubeURL(urlString)
    }

    /// Extract the 11-character video ID from various YouTube URL formats.
    static func extractVideoId(from urlString: String) -> String? {
        // youtu.be/VIDEO_ID
        if urlString.contains("youtu.be/") {
            guard let url = URL(string: urlString) else { return nil }
            let pathComponent = url.pathComponents.dropFirst().first ?? ""
            let id = String(pathComponent.prefix(11))
            return id.isEmpty ? nil : id
        }

        // youtube.com/watch?v=VIDEO_ID
        if let components = URLComponents(string: urlString),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !vParam.isEmpty {
            return String(vParam.prefix(11))
        }

        // youtube.com/v/VIDEO_ID, /embed/VIDEO_ID, /shorts/VIDEO_ID
        if urlString.contains("youtube.com") {
            guard let url = URL(string: urlString) else { return nil }
            let parts = url.pathComponents
            for keyword in ["v", "embed", "shorts"] {
                if let idx = parts.firstIndex(of: keyword), idx + 1 < parts.count {
                    let id = parts[idx + 1]
                    return id.isEmpty ? nil : String(id.prefix(11))
                }
            }
        }

        return nil
    }

    // MARK: - InnerTube API

    /// Use the InnerTube /player API to get caption track URLs
    /// that actually return content. The WEB client's caption URLs have been
    /// returning empty responses since early 2026.
    private func fetchCaptionCandidatesViaInnerTube(
        videoId: String,
        apiKey: String,
        context: [String: Any]
    ) async throws -> [CaptionTrackCandidate] {
        let json = try await requestPlayerResponse(videoId: videoId, apiKey: apiKey, context: context)

        // Check playability
        if let status = json["playabilityStatus"] as? [String: Any],
           let statusStr = status["status"] as? String, statusStr != "OK" {
            let reason = status["reason"] as? String ?? "unknown"
            if reason.contains("bot") || reason.contains("Sign in") {
                throw YouTubeTranscriptError.parsingFailed("Request blocked by YouTube: \(reason)")
            }
            throw YouTubeTranscriptError.noTranscriptAvailable
        }

        // Extract caption tracks
        guard let captions = json["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]],
              !tracks.isEmpty else {
            throw YouTubeTranscriptError.noTranscriptAvailable
        }

        let sortedTracks = tracks.sorted { lhs, rhs in
            rank(track: lhs) < rank(track: rhs)
        }

        let candidates = sortedTracks.compactMap { track -> CaptionTrackCandidate? in
            guard let baseURLString = track["baseUrl"] as? String else { return nil }
            let cleanedURL = baseURLString.replacingOccurrences(of: "&fmt=srv3", with: "")
            guard !cleanedURL.contains("&exp=xpe") else { return nil }
            guard let captionURL = URL(string: cleanedURL) else { return nil }
            return CaptionTrackCandidate(
                url: captionURL,
                languageCode: track["languageCode"] as? String ?? "unknown",
                kind: (track["kind"] as? String) ?? "manual"
            )
        }

        guard !candidates.isEmpty else {
            logger.warning("Caption URLs require PoToken or were invalid")
            throw YouTubeTranscriptError.noTranscriptAvailable
        }

        let summary = candidates.prefix(3).map { "\($0.languageCode):\($0.kind)" }.joined(separator: ", ")
        logger.info("Selected \(candidates.count) caption candidate(s) via InnerTube: \(summary)")
        return candidates
    }

    /// One InnerTube `/player` answer for a video: its playability, its
    /// details and its caption tracks.
    private func requestPlayerResponse(
        videoId: String,
        apiKey: String,
        context: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else {
            throw YouTubeTranscriptError.fetchFailed
        }

        let payload: [String: Any] = [
            "context": context,
            "videoId": videoId,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeTranscriptError.fetchFailed
        }

        if httpResponse.statusCode == 429 {
            throw YouTubeTranscriptError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("InnerTube API returned HTTP \(httpResponse.statusCode)")
            throw YouTubeTranscriptError.fetchFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeTranscriptError.parsingFailed("Invalid InnerTube response")
        }
        return json
    }

    // MARK: - Chapter Marker Parsing

    /// Pull chapter markers out of a `/next` response. Prefers the player-bar
    /// markers (`multiMarkersPlayerBarRenderer`), falling back to the engagement
    /// panel's macro-marker list. Returns them sorted, de-duplicated by start
    /// time, and free of empty titles.
    static func parseChapterMarkers(from json: Any) -> [VideoChapter] {
        var chapters = parsePlayerBarChapters(from: json)
        if chapters.isEmpty {
            chapters = parseMacroMarkerChapters(from: json)
        }

        let sorted = chapters
            .compactMap { chapter -> VideoChapter? in
                let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty,
                      chapter.startSeconds.isFinite,
                      chapter.startSeconds >= 0,
                      chapter.startSeconds <= Double(Int.max) else {
                    return nil
                }
                return VideoChapter(startSeconds: chapter.startSeconds, title: title)
            }
            .sorted { $0.startSeconds < $1.startSeconds }

        var result: [VideoChapter] = []
        var seenStarts = Set<Int>()
        for chapter in sorted where seenStarts.insert(Int(chapter.startSeconds.rounded())).inserted {
            result.append(chapter)
        }
        return result
    }

    private static func parsePlayerBarChapters(from json: Any) -> [VideoChapter] {
        guard let bar = firstValue(forKey: "multiMarkersPlayerBarRenderer", in: json) as? [String: Any],
              let markersMap = bar["markersMap"] as? [[String: Any]] else {
            return []
        }

        // The map can also carry a heatmap entry, which has no `chapters` array;
        // take the first entry that actually holds chapters.
        for entry in markersMap {
            guard let value = entry["value"] as? [String: Any],
                  let items = value["chapters"] as? [[String: Any]] else { continue }
            let chapters = items.compactMap { item -> VideoChapter? in
                guard let renderer = item["chapterRenderer"] as? [String: Any],
                      let title = simpleText(renderer["title"]), !title.isEmpty,
                      let millis = doubleValue(renderer["timeRangeStartMillis"]) else { return nil }
                return VideoChapter(startSeconds: millis / 1000, title: title)
            }
            if !chapters.isEmpty { return chapters }
        }
        return []
    }

    private static func parseMacroMarkerChapters(from json: Any) -> [VideoChapter] {
        guard let renderer = firstValue(forKey: "macroMarkersListRenderer", in: json) as? [String: Any],
              let contents = renderer["contents"] as? [[String: Any]] else {
            return []
        }
        return contents.compactMap { entry -> VideoChapter? in
            guard let item = entry["macroMarkersListItemRenderer"] as? [String: Any],
                  let title = simpleText(item["title"]), !title.isEmpty,
                  let onTap = item["onTap"] as? [String: Any],
                  let watch = onTap["watchEndpoint"] as? [String: Any],
                  let startSeconds = doubleValue(watch["startTimeSeconds"]) else { return nil }
            return VideoChapter(startSeconds: startSeconds, title: title)
        }
    }

    /// Depth-first search for the first value stored under `key` anywhere in a
    /// decoded JSON tree. The chapter renderers sit several renderers deep and
    /// YouTube reshuffles that path often, so matching by key is sturdier than
    /// hard-coding it.
    private static func firstValue(forKey key: String, in json: Any) -> Any? {
        if let dict = json as? [String: Any] {
            if let direct = dict[key] { return direct }
            for value in dict.values {
                if let found = firstValue(forKey: key, in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = firstValue(forKey: key, in: value) { return found }
            }
        }
        return nil
    }

    private static func simpleText(_ object: Any?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let text = dict["simpleText"] as? String { return text }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func doubleValue(_ object: Any?) -> Double? {
        if let number = object as? NSNumber { return number.doubleValue }
        if let string = object as? String { return Double(string) }
        return nil
    }

    // MARK: - Transcript Parsing

    private func fetchAndParseTranscript(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeTranscriptError.fetchFailed
        }
        if httpResponse.statusCode == 429 {
            throw YouTubeTranscriptError.rateLimited
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw YouTubeTranscriptError.fetchFailed
        }

        guard let xml = String(data: data, encoding: .utf8) else {
            throw YouTubeTranscriptError.fetchFailed
        }

        return try Self.transcript(fromCaptionXML: xml)
    }

    /// Timed-text XML in, stored transcript out — the whole decode-and-format
    /// contract in one seam the tests can reach.
    static func transcript(fromCaptionXML xml: String) throws -> String {
        let segments = try parseCaptionSegments(from: xml)
        let transcript = formatTimedTranscript(from: segments)
        guard !transcript.isEmpty else {
            throw YouTubeTranscriptError.noTranscriptAvailable
        }
        return transcript
    }

    private static func parseCaptionSegments(from xml: String) throws -> [CaptionSegment] {
        // Parse <text start="..." dur="...">content</text> elements.
        let textPattern = #"<text\b([^>]*)>(.*?)</text>"#
        guard let regex = try? NSRegularExpression(pattern: textPattern, options: .dotMatchesLineSeparators) else {
            throw YouTubeTranscriptError.parsingFailed("Invalid regex")
        }

        let nsXML = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))

        var segments: [CaptionSegment] = []
        for match in matches {
            guard let attrsRange = Range(match.range(at: 1), in: xml),
                  let textRange = Range(match.range(at: 2), in: xml) else { continue }
            let attrs = String(xml[attrsRange])
            var text = String(xml[textRange])

            // YouTube's timed-text XML escapes an already-escaped caption, so a
            // literal "&" arrives as "&amp;amp;" and an apostrophe as "&amp;#39;".
            // One decoding level leaves a visible "&amp;" in the stored
            // transcript ("R&amp;D", "M&amp;M"), which every reader then shows
            // verbatim because reader text is escaped, not parsed as HTML.
            // A soft hyphen in a caption is a line-break hint, not a character.
            text = text.decodingDoubleEscapedHTMLCharacterReferences().removingSoftHyphens()
            text = text.replacingOccurrences(of: "\n", with: " ")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            let start = Self.captionAttribute("start", in: attrs).flatMap(Double.init) ?? 0
            let duration = Self.captionAttribute("dur", in: attrs).flatMap(Double.init)
            segments.append(CaptionSegment(start: start, duration: duration, text: text))
        }

        guard !segments.isEmpty else {
            throw YouTubeTranscriptError.noTranscriptAvailable
        }

        return segments
    }

    private static func formatTimedTranscript(from segments: [CaptionSegment]) -> String {
        var blocks: [(start: Double, text: String)] = []
        var currentStart: Double?
        var currentEnd: Double?
        var currentText: [String] = []
        var currentWordCount = 0

        func flush() {
            guard let start = currentStart else { return }
            let text = currentText.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append((start, text))
            }
            currentStart = nil
            currentEnd = nil
            currentText = []
            currentWordCount = 0
        }

        for segment in segments {
            let gap = currentEnd.map { segment.start - $0 } ?? 0
            if currentStart == nil || gap > 3 || currentWordCount >= 75 {
                flush()
                currentStart = segment.start
            }

            currentText.append(segment.text)
            currentWordCount += segment.text.split(separator: " ").count
            currentEnd = segment.end ?? segment.start

            if segment.text.range(of: #"[.!?]["')\]]?$"#, options: .regularExpression) != nil,
               currentWordCount >= 35 {
                flush()
            }
        }
        flush()

        return blocks
            .map { "[\(Self.displayTime($0.start))] \($0.text)" }
            .joined(separator: "\n\n")
    }

    private static func captionAttribute(_ name: String, in attrs: String) -> String? {
        let pattern = #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name) + #"=(["'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let valueRange = Range(match.range(at: 2), in: attrs) else { return nil }
        return String(attrs[valueRange])
    }

    private static func displayTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func fetchTranscriptWithFallbacks(
        videoId: String,
        apiKey: String,
        primaryCandidates: [CaptionTrackCandidate]
    ) async throws -> String {
        do {
            return try await fetchTranscript(fromCandidates: primaryCandidates)
        } catch YouTubeTranscriptError.rateLimited {
            logger.warning("Caption endpoint rate limited for \(videoId); retrying with alternate client/tracks")
            try? await Task.sleep(for: .seconds(1))
            let alternateCandidates = try await fetchCaptionCandidatesViaInnerTube(
                videoId: videoId,
                apiKey: apiKey,
                context: Self.innertubeIOSContext
            )
            let merged = uniqueCandidates(primaryCandidates + alternateCandidates)
            return try await fetchTranscript(fromCandidates: merged)
        }
    }

    private func fetchTranscript(fromCandidates candidates: [CaptionTrackCandidate]) async throws -> String {
        guard !candidates.isEmpty else {
            throw YouTubeTranscriptError.noTranscriptAvailable
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                return try await fetchAndParseTranscript(from: candidate.url)
            } catch YouTubeTranscriptError.rateLimited {
                lastError = YouTubeTranscriptError.rateLimited
                continue
            } catch YouTubeTranscriptError.noTranscriptAvailable {
                lastError = YouTubeTranscriptError.noTranscriptAvailable
                continue
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? YouTubeTranscriptError.fetchFailed
    }

    private func uniqueCandidates(_ candidates: [CaptionTrackCandidate]) -> [CaptionTrackCandidate] {
        var seen = Set<String>()
        var result: [CaptionTrackCandidate] = []
        for candidate in candidates {
            let key = candidate.url.absoluteString
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func rank(track: [String: Any]) -> Int {
        let lang = track["languageCode"] as? String ?? ""
        let kind = track["kind"] as? String ?? ""
        if lang.hasPrefix("en") && kind != "asr" { return 0 }
        if lang.hasPrefix("en") { return 1 }
        return 2
    }

    // MARK: - Video Metadata

    /// What one metadata lookup learned about a video.
    ///
    /// The distinction matters to callers that remember their misses: a
    /// private or deleted video stays that way however often it is asked
    /// about, while a dropped connection says nothing about the video at all.
    enum MetadataLookup: Equatable, Sendable {
        case found(VideoMetadata)
        /// YouTube answered, and the answer is that it has no public video
        /// here: private, deleted, or never there.
        case unavailable
        /// The request itself failed, or the answer was unreadable; worth
        /// asking again another time.
        case failed

        var metadata: VideoMetadata? {
            if case .found(let metadata) = self { return metadata }
            return nil
        }
    }

    /// A video's title, uploader and thumbnail, for naming it in the library.
    /// Not affected by the bot detection that gates the watch page.
    func fetchVideoMetadata(videoId: String) async -> VideoMetadata? {
        await lookUpVideoMetadata(videoId: videoId).metadata
    }

    /// `fetchVideoMetadata`, keeping the reason a lookup came back empty.
    ///
    /// oEmbed answers first: one small JSON request. It cannot answer alone,
    /// because it refuses with the same 401 a private video and a public one
    /// whose uploader turned embedding off — every Stanford Online lecture
    /// among them. That is how lectures stay filed under
    /// "www.youtube.com", each remembered as private at every launch. So when oEmbed does not name the uploader, the InnerTube
    /// player (the ANDROID client the transcript fetch reads, which embedding
    /// does not gate) is asked, and only its word makes a video unavailable.
    func lookUpVideoMetadata(videoId: String) async -> MetadataLookup {
        let oEmbed = await fetchOEmbedMetadata(videoId: videoId)
        if let oEmbed, Self.channelName(of: oEmbed) != nil {
            return .found(oEmbed)
        }
        let player = await lookUpPlayerMetadata(videoId: videoId)
        return Self.combinedMetadataLookup(oEmbed: oEmbed, player: player)
    }

    /// Fetch the video title, for a transcript or a meeting that has none.
    func fetchVideoTitle(videoId: String) async -> String? {
        await fetchVideoMetadata(videoId: videoId)?.title
    }

    /// The uploader `metadata` names, or nil when it names none.
    static func channelName(of metadata: VideoMetadata) -> String? {
        let channel = metadata.channelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return channel.isEmpty ? nil : channel
    }

    /// What oEmbed and the player said, together. The player names the
    /// uploader; oEmbed's title and thumbnail stay when it gave them, since
    /// they are what every other path stores. Unavailable is the player's
    /// verdict alone: oEmbed's refusal cannot tell a private video from one
    /// that may not be embedded.
    static func combinedMetadataLookup(oEmbed: VideoMetadata?, player: MetadataLookup) -> MetadataLookup {
        switch player {
        case .found(let details):
            return .found(VideoMetadata(
                title: oEmbed?.title ?? details.title,
                channelName: channelName(of: details) ?? oEmbed.flatMap { channelName(of: $0) },
                thumbnailURL: oEmbed?.thumbnailURL ?? details.thumbnailURL
            ))
        case .unavailable:
            return oEmbed.map(MetadataLookup.found) ?? .unavailable
        case .failed:
            return oEmbed.map(MetadataLookup.found) ?? .failed
        }
    }

    /// What an InnerTube `/player` answer says about a video. A video the
    /// player describes carries `videoDetails` whatever its playability, so an
    /// embed-disabled video still names its uploader. One it does not
    /// describe, under a status other than OK, is YouTube's verdict (a deleted
    /// video answers ERROR, a private one LOGIN_REQUIRED) — except a bot
    /// check, which is about the request and not the video.
    static func playerMetadataLookup(fromPlayerResponse json: [String: Any]) -> MetadataLookup {
        if let details = json["videoDetails"] as? [String: Any],
           let rawTitle = details["title"] as? String,
           let title = sanitizedVideoTitle(rawTitle) {
            let author = (details["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The player's thumbnails are signed URLs; the stable one is
            // derived from the video ID where a thumbnail is stored.
            return .found(VideoMetadata(title: title, channelName: author.isEmpty ? nil : author, thumbnailURL: nil))
        }
        guard let status = json["playabilityStatus"] as? [String: Any],
              let state = status["status"] as? String, state != "OK" else {
            return .failed
        }
        let reason = (status["reason"] as? String ?? "").lowercased()
        return reason.contains("bot") ? .failed : .unavailable
    }

    private func lookUpPlayerMetadata(videoId: String) async -> MetadataLookup {
        do {
            let json = try await requestPlayerResponse(
                videoId: videoId,
                apiKey: Self.fallbackAPIKey,
                context: Self.innertubeContext
            )
            return Self.playerMetadataLookup(fromPlayerResponse: json)
        } catch {
            logger.warning("InnerTube metadata fetch failed for \(videoId): \(error.localizedDescription)")
            return .failed
        }
    }

    /// Video metadata from YouTube's oEmbed API, or nil when it gave none.
    private func fetchOEmbedMetadata(videoId: String) async -> VideoMetadata? {
        let watchURL = "https://www.youtube.com/watch?v=\(videoId)"
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: watchURL),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let json = try JSONDecoder().decode(OEmbedResponse.self, from: data)
            guard let title = Self.sanitizedVideoTitle(json.title) else { return nil }
            logger.info("Metadata via oEmbed: \(title)")
            return VideoMetadata(
                title: title,
                channelName: json.authorName,
                thumbnailURL: json.thumbnailURL
            )
        } catch {
            logger.warning("oEmbed metadata fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    static func sanitizedVideoTitle(_ title: String) -> String? {
        YouTubeURLMetadata.sanitizedVideoTitle(title)
    }

    private struct OEmbedResponse: Decodable {
        let title: String
        let authorName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }
}

// MARK: - Playlist Parsing

struct YouTubePlaylistItem: Sendable {
    let videoId: String
    let title: String
    let playlistIndex: Int?
    /// Uploader channel name, when the feed provides it (Data API
    /// `videoOwnerChannelTitle` or the playlist page's byline).
    let channelTitle: String?
    /// When the video entered this playlist. For the Liked feed that is when it
    /// was liked. nil for the keyless playlist-page scrape, which has no dates.
    let likedAt: Date?
    /// When the video was published to YouTube. Same nil caveat as `likedAt`.
    let videoPublishedAt: Date?

    init(
        videoId: String,
        title: String,
        playlistIndex: Int? = nil,
        channelTitle: String? = nil,
        likedAt: Date? = nil,
        videoPublishedAt: Date? = nil
    ) {
        self.videoId = videoId
        self.title = YouTubeTranscriptService.sanitizedVideoTitle(title) ?? "Untitled Video"
        self.playlistIndex = playlistIndex
        let trimmedChannel = channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelTitle = (trimmedChannel?.isEmpty == false) ? trimmedChannel : nil
        self.likedAt = likedAt
        self.videoPublishedAt = videoPublishedAt
    }

    var url: String { "https://www.youtube.com/watch?v=\(videoId)" }
}

/// Fetches all video entries from a YouTube playlist page.
actor YouTubePlaylistService {

    static let shared = YouTubePlaylistService()

    private let logger = Logger(subsystem: "com.foreverlm", category: "YouTubePlaylist")
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Check if a URL is a YouTube playlist URL.
    static func isPlaylistURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("youtube.com/playlist") && lower.contains("list=")
    }

    /// Extract the playlist ID from a YouTube playlist URL.
    static func extractPlaylistId(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let listParam = components.queryItems?.first(where: { $0.name == "list" })?.value,
              !listParam.isEmpty else { return nil }
        return listParam
    }

    /// Fetch all videos in a playlist. Returns (playlistTitle, [items]).
    func fetchPlaylist(from urlString: String) async throws -> (title: String, items: [YouTubePlaylistItem]) {
        guard let playlistId = Self.extractPlaylistId(from: urlString) else {
            throw YouTubeTranscriptError.invalidURL
        }

        logger.info("Fetching playlist: \(playlistId)")

        let html = try await fetchPlaylistPage(playlistId: playlistId)

        // Extract innertube context from the page for continuation requests
        let apiKey = extractInnertubeApiKey(from: html) ?? "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        let visitorData = extractVisitorData(from: html)

        // Extract ytInitialData JSON from the page
        guard let jsonString = extractYtInitialData(from: html) else {
            throw YouTubeTranscriptError.parsingFailed("Could not find ytInitialData in playlist page")
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw YouTubeTranscriptError.parsingFailed("Could not parse ytInitialData JSON")
        }

        // Extract playlist title
        let playlistTitle = extractPlaylistTitle(from: json) ?? "YouTube Playlist"

        // Extract video items (first page from ytInitialData)
        var (items, continuation) = Self.parsePlaylistPageItems(from: json)

        guard !items.isEmpty else {
            throw YouTubeTranscriptError.parsingFailed("No videos found in playlist")
        }

        // Follow continuation tokens to get every video beyond the first ~100.
        // Tracking every token terminates malformed cyclic responses without
        // imposing an arbitrary playlist-size cap.
        var page = 1
        var seenTokens = Set<String>()
        while let token = continuation {
            guard seenTokens.insert(token).inserted else {
                logger.warning("Playlist continuation token cycled; stopping to avoid an infinite loop")
                break
            }
            page += 1
            logger.info("Fetching playlist page \(page) (have \(items.count) videos so far)")
            let (moreItems, nextContinuation) = try await fetchContinuation(token: token, apiKey: apiKey, visitorData: visitorData)
            items.append(contentsOf: moreItems)
            continuation = nextContinuation
        }

        items = canonicalPlaylistOrder(items)

        logger.info("Found \(items.count) videos in playlist '\(playlistTitle)'")
        return (playlistTitle, items)
    }

    private func fetchPlaylistPage(playlistId: String) async throws -> String {
        guard let url = URL(string: "https://www.youtube.com/playlist?list=\(playlistId)") else {
            throw YouTubeTranscriptError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("CONSENT=PENDING+987; SOCS=CAESEwgDEgk3NDQ1MTgxMTIaAmVuIAEaBgiA_LyaBg",
                        forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw YouTubeTranscriptError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw YouTubeTranscriptError.fetchFailed
        }

        return html
    }

    /// Extract the innertube API key from the page HTML (e.g. from INNERTUBE_API_KEY).
    private func extractInnertubeApiKey(from html: String) -> String? {
        // Patterns: "INNERTUBE_API_KEY":"..." or "innertubeApiKey":"..."
        let patterns = ["\"INNERTUBE_API_KEY\":\"", "\"innertubeApiKey\":\""]
        for pattern in patterns {
            guard let startRange = html.range(of: pattern) else { continue }
            let after = html[startRange.upperBound...]
            guard let endQuote = after.firstIndex(of: "\"") else { continue }
            let key = String(after[after.startIndex..<endQuote])
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// Extract visitorData from the page HTML (from ytcfg or responseContext).
    private func extractVisitorData(from html: String) -> String? {
        let patterns = ["\"visitorData\":\"", "\"VISITOR_DATA\":\""]
        for pattern in patterns {
            guard let startRange = html.range(of: pattern) else { continue }
            let after = html[startRange.upperBound...]
            guard let endQuote = after.firstIndex(of: "\"") else { continue }
            let data = String(after[after.startIndex..<endQuote])
            if !data.isEmpty { return data }
        }
        return nil
    }

    private func extractYtInitialData(from html: String) -> String? {
        // Look for: var ytInitialData = {...};
        let markers = ["var ytInitialData = ", "window[\"ytInitialData\"] = "]
        for marker in markers {
            guard let startRange = html.range(of: marker) else { continue }
            let afterMarker = html[startRange.upperBound...]

            // Find the opening brace
            guard let braceStart = afterMarker.firstIndex(of: "{") else { continue }

            // Find matching closing brace
            var depth = 0
            var idx = braceStart
            while idx < afterMarker.endIndex {
                let ch = afterMarker[idx]
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(afterMarker[braceStart...idx])
                    }
                }
                idx = afterMarker.index(after: idx)
            }
        }
        return nil
    }

    private func extractPlaylistTitle(from json: [String: Any]) -> String? {
        // Navigate: metadata.playlistMetadataRenderer.title
        if let metadata = json["metadata"] as? [String: Any],
           let renderer = metadata["playlistMetadataRenderer"] as? [String: Any],
           let title = renderer["title"] as? String {
            return title
        }
        // Fallback: header.playlistHeaderRenderer.title.simpleText
        if let header = json["header"] as? [String: Any],
           let renderer = header["playlistHeaderRenderer"] as? [String: Any],
           let titleObj = renderer["title"] as? [String: Any],
           let title = titleObj["simpleText"] as? String {
            return title
        }
        return nil
    }

    /// Extract playlist items and an optional continuation token from ytInitialData.
    ///
    /// Handles both markups YouTube serves. The classic shape nests
    /// `playlistVideoRenderer` entries inside a `playlistVideoListRenderer`
    /// wrapper with a `continuationItemRenderer` pager; the lockup shape
    /// (rolled out to playlist pages in 2026) puts `lockupViewModel` entries
    /// directly in the item section with a `continuationItemViewModel` pager.
    /// Path: contents.twoColumnBrowseResultsRenderer.tabs[0].tabRenderer.content
    ///       .sectionListRenderer.contents[].itemSectionRenderer.contents[]
    static func parsePlaylistPageItems(from json: [String: Any]) -> (items: [YouTubePlaylistItem], continuation: String?) {
        guard let contents = json["contents"] as? [String: Any],
              let twoCol = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = twoCol["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionList["contents"] as? [[String: Any]] else {
            return ([], nil)
        }

        var items: [YouTubePlaylistItem] = []
        var continuation: String?

        for section in sectionContents {
            if let itemSection = section["itemSectionRenderer"] as? [String: Any],
               let itemContents = itemSection["contents"] as? [[String: Any]] {
                appendPlaylistEntries(itemContents, to: &items, continuation: &continuation)
            }
        }

        return (items, continuation)
    }

    /// Append every playlist entry in `entries` to `items`, capturing the next
    /// continuation token when one is present. Accepts entries from either
    /// markup, recursing into the classic `playlistVideoListRenderer` wrapper.
    private static func appendPlaylistEntries(
        _ entries: [[String: Any]],
        to items: inout [YouTubePlaylistItem],
        continuation: inout String?
    ) {
        for entry in entries {
            if let wrapper = entry["playlistVideoListRenderer"] as? [String: Any],
               let wrapped = wrapper["contents"] as? [[String: Any]] {
                appendPlaylistEntries(wrapped, to: &items, continuation: &continuation)
            }
            if let video = entry["playlistVideoRenderer"] as? [String: Any],
               let item = playlistItem(fromPlaylistVideoRenderer: video) {
                items.append(item)
            }
            if let lockup = entry["lockupViewModel"] as? [String: Any],
               let item = playlistItem(fromLockup: lockup) {
                items.append(item)
            }
            if let token = continuationToken(in: entry) {
                continuation = token
            }
        }
    }

    private static func continuationToken(in entry: [String: Any]) -> String? {
        // Classic pager: continuationItemRenderer.continuationEndpoint.continuationCommand.token
        if let renderer = entry["continuationItemRenderer"] as? [String: Any],
           let endpoint = renderer["continuationEndpoint"] as? [String: Any],
           let command = endpoint["continuationCommand"] as? [String: Any],
           let token = command["token"] as? String,
           !token.isEmpty {
            return token
        }
        // Lockup pager: continuationItemViewModel.continuationCommand
        //               .innertubeCommand.continuationCommand.token
        if let viewModel = entry["continuationItemViewModel"] as? [String: Any],
           let outerCommand = viewModel["continuationCommand"] as? [String: Any],
           let innertube = outerCommand["innertubeCommand"] as? [String: Any],
           let command = innertube["continuationCommand"] as? [String: Any],
           let token = command["token"] as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    private static func playlistItem(fromPlaylistVideoRenderer video: [String: Any]) -> YouTubePlaylistItem? {
        guard let videoId = video["videoId"] as? String, !videoId.isEmpty else { return nil }
        let index = (video["index"] as? [String: Any])
            .flatMap(text(from:))
            .flatMap(integerFromDigits(in:))
        return YouTubePlaylistItem(
            videoId: videoId,
            title: (video["title"] as? [String: Any]).flatMap(text(from:)) ?? "Untitled Video",
            playlistIndex: index,
            channelTitle: channelTitle(fromBylinesOf: video)
        )
    }

    /// A lockup is a playlist entry only when it is a video lockup — related
    /// rails reuse the same shape for playlists and mixes, whose `contentId`
    /// is not a video id.
    private static func playlistItem(fromLockup lockup: [String: Any]) -> YouTubePlaylistItem? {
        if let contentType = lockup["contentType"] as? String,
           contentType != "LOCKUP_CONTENT_TYPE_VIDEO" {
            return nil
        }
        guard let videoId = lockup["contentId"] as? String, !videoId.isEmpty else { return nil }
        let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title = (metadata?["title"] as? [String: Any])?["content"] as? String
        return YouTubePlaylistItem(
            videoId: videoId,
            title: title ?? "Untitled Video",
            playlistIndex: lockupPlaylistIndex(lockup),
            channelTitle: lockupChannelTitle(metadata)
        )
    }

    /// The lockup's watch endpoint carries the 0-based playlist position; the
    /// classic markup displayed a 1-based index, so shift to match.
    private static func lockupPlaylistIndex(_ lockup: [String: Any]) -> Int? {
        guard let rendererContext = lockup["rendererContext"] as? [String: Any],
              let commandContext = rendererContext["commandContext"] as? [String: Any],
              let onTap = commandContext["onTap"] as? [String: Any],
              let innertube = onTap["innertubeCommand"] as? [String: Any],
              let watchEndpoint = innertube["watchEndpoint"] as? [String: Any],
              let index = watchEndpoint["index"] as? Int else {
            return nil
        }
        return index + 1
    }

    /// The channel byline is the metadata part whose text links somewhere (a
    /// channel browse endpoint); plain view-count/age parts carry no command.
    private static func lockupChannelTitle(_ metadata: [String: Any]?) -> String? {
        guard let contentMetadata = (metadata?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
              let rows = contentMetadata["metadataRows"] as? [[String: Any]] else {
            return nil
        }
        for row in rows {
            guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
            for part in parts {
                guard let text = part["text"] as? [String: Any],
                      let content = text["content"] as? String,
                      !content.isEmpty,
                      text["commandRuns"] != nil else { continue }
                return content
            }
        }
        return nil
    }

    /// Fetch additional playlist items using YouTube's browse API with a continuation token.
    private func fetchContinuation(token: String, apiKey: String, visitorData: String?) async throws -> (items: [YouTubePlaylistItem], continuation: String?) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?key=\(apiKey)&prettyPrint=false") else {
            throw YouTubeTranscriptError.invalidURL
        }

        var clientContext: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": "2.20260301.00.00",
            "hl": "en",
            "gl": "US"
        ]
        if let visitorData {
            clientContext["visitorData"] = visitorData
        }

        let body: [String: Any] = [
            "context": [
                "client": clientContext
            ],
            "continuation": token
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("CONSENT=PENDING+987; SOCS=CAESEwgDEgk3NDQ1MTgxMTIaAmVuIAEaBgiA_LyaBg",
                        forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        // A failed request or an unparseable response is NOT the end of the
        // playlist — treating it as such would silently truncate the results.
        // Throw so the caller surfaces the failure instead of returning a
        // partial playlist. A legitimate end of the playlist is signalled by
        // an absent continuation token in a successfully parsed response.
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Playlist continuation: no HTTP response")
            throw YouTubeTranscriptError.fetchFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Playlist continuation failed: HTTP \(httpResponse.statusCode)")
            throw YouTubeTranscriptError.fetchFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            logger.error("Playlist continuation: could not parse JSON — \(preview)")
            throw YouTubeTranscriptError.parsingFailed("Could not parse playlist continuation response")
        }

        let result = Self.parseContinuationItems(from: json)
        if result.items.isEmpty {
            let keys = json.keys.sorted().joined(separator: ", ")
            logger.warning("Playlist continuation: parsed JSON but found 0 items. Top-level keys: \(keys)")
        }
        return result
    }

    /// Parse the browse API continuation response for playlist items.
    /// Response structure: onResponseReceivedActions[0].appendContinuationItemsAction
    /// .continuationItems, holding entries in either markup.
    static func parseContinuationItems(from json: [String: Any]) -> (items: [YouTubePlaylistItem], continuation: String?) {
        guard let actions = json["onResponseReceivedActions"] as? [[String: Any]] else {
            return ([], nil)
        }

        var items: [YouTubePlaylistItem] = []
        var continuation: String?

        for action in actions {
            guard let appendAction = action["appendContinuationItemsAction"] as? [String: Any],
                  let contItems = appendAction["continuationItems"] as? [[String: Any]] else {
                continue
            }
            appendPlaylistEntries(contItems, to: &items, continuation: &continuation)
        }

        return (items, continuation)
    }

    private func canonicalPlaylistOrder(_ items: [YouTubePlaylistItem]) -> [YouTubePlaylistItem] {
        var seenVideoIds = Set<String>()
        let uniqueItems = items.filter { item in
            seenVideoIds.insert(item.videoId).inserted
        }

        guard uniqueItems.allSatisfy({ $0.playlistIndex != nil }) else {
            return uniqueItems
        }

        return uniqueItems.sorted {
            guard let lhs = $0.playlistIndex, let rhs = $1.playlistIndex else {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return lhs < rhs
        }
    }

    private static func channelTitle(fromBylinesOf video: [String: Any]) -> String? {
        for key in ["shortBylineText", "longBylineText"] {
            if let byline = video[key] as? [String: Any],
               let name = text(from: byline),
               !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func integerFromDigits(in text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func text(from textObj: [String: Any]) -> String? {
        if let text = textObj["simpleText"] as? String {
            return text
        }
        if let runs = textObj["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}

// MARK: - Readable Transcript Markers

/// Sets a readable transcript's time markers back on the words they time,
/// and holds its words to what the captions say.
///
/// Transcript Formatting rewrites a video's captions into sentences,
/// paragraphs and headings (`Prompts.readableYouTubeTranscriptFormatting`),
/// and is asked to keep each `[m:ss]` at the start of its paragraph. It does
/// not do so reliably. Measured against YouTube's own captions
/// for fourteen lectures, 76 of 900 stored
/// markers timed words said elsewhere, most often where the model began a
/// section: "Mitochondrial Cell Biology 3" lost 11:52 before "Mitochondria
/// and the ER" and put each later marker on the text before its own, and
/// "Mitochondrial Cell Biology 2" kept 18 of the captions' 31, its paragraph
/// marked 2:53 said at 6:17. A marker on the wrong words sends the Reader's
/// click, a chat's citation and a quiz's Rewatch to the wrong moment, and a
/// quote timed within its paragraph (`LectureQuizTimeline`) lands after the
/// words instead of on them.
///
/// The captions the model read have every marker on its words, so the
/// model's own markers are not kept. Its words are aligned with the
/// captions' (letters and digits, case aside, in order), and its text is cut
/// again into one paragraph per caption block, each opening with that
/// block's marker. A heading stays where the model put it: inside a block,
/// the block's paragraph is cut there and the words after it are timed
/// within the block. A block none of whose words the model kept, such as an
/// ad read taken out, has no paragraph. `anchored` keeps the model's words,
/// punctuation and headings as they are, in their order; `checked` also
/// holds those words to the captions (see there).
enum ReadableTranscriptMarkers {
    /// Caption words aligned per step: a long lecture costs in proportion to
    /// its length, and a stretch the model dropped or repeated is still
    /// found inside one step.
    static let alignmentWindow = 600

    private static let marker = try! NSRegularExpression(pattern: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#)
    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}\s+\S"#)

    /// What the model writes where it would open a paragraph with a marker
    /// it cannot read off the captions. The captions' markers replace it.
    private static let unreadMarker = "[?]"

    /// Characters a word's parts are joined by, which one side may write and
    /// the other not: the model's "all-gathers" is the captions' "all
    /// gathers", its "cross rack" their "cross-rack", its "scene—is" two
    /// words.
    private static let joiners: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "/"]

    /// A word of the formatted text as written, and what it is aligned by:
    /// the letters and digits of each of its parts (`joiners`).
    private struct Token {
        var text: String
        let words: [String]
    }

    /// A formatted transcript as the alignment reads it.
    private struct Formatted {
        var tokens: [Token] = []
        /// Each heading line with the number of tokens before it.
        var headings: [(position: Int, line: String)] = []
        /// The tokens' words in order, and the token each belongs to.
        var words: [String] = []
        var wordToken: [Int] = []
    }

    /// Captions as the alignment reads them.
    private struct Captions {
        var blocks: [(time: String?, text: String)] = []
        /// Each caption word as written.
        var pieces: [String] = []
        /// The parts of the caption words in order (`joiners`), the block
        /// each is in and the written word it belongs to.
        var words: [String] = []
        var wordBlock: [Int] = []
        var wordPiece: [Int] = []

        var isTimed: Bool { blocks.contains { $0.time != nil } }
    }

    /// `formatted` with each of `raw`'s markers opening the paragraph of the
    /// words it times. Unchanged when `raw` has no markers or no words are
    /// shared.
    static func anchored(_ formatted: String, to raw: String) -> String {
        let captions = Self.captions(of: raw)
        guard captions.isTimed else { return formatted }
        let text = self.formatted(formatted)
        let pairs = align(captions.words, text.words)
        guard !pairs.isEmpty else { return formatted }
        return layout(
            text.tokens,
            headings: text.headings,
            pairs: pairs.map { ($0.raw, text.wordToken[$0.formatted]) },
            captions: captions
        )
    }

    // MARK: Fidelity

    /// A formatted transcript held to its captions.
    struct Checked {
        /// The transcript, its markers set as `anchored` sets them.
        let text: String
        /// Caption words the model left out, put back in its text.
        let restoredWords: Int
        /// The model's words that no caption says there, taken out.
        let removedWords: Int
        /// Words in the captions and in the model's text, as aligned.
        let captionWords: Int
        let formattedWords: Int
        /// Each run put back, as the marker of the block it begins in and its
        /// length ("3:44 +364"), and each run taken out, as its opening
        /// words: what the log says the model got wrong.
        let restored: [String]
        let removed: [String]
    }

    /// The share of the captions put back beyond which the model's text is
    /// refused rather than repaired, and the captions stay. A caption run
    /// put back reads as the captions do, unpunctuated where they are, so
    /// past this share the text is more patchwork than formatting. What the
    /// model repeated or invented is taken out at any length: its other
    /// words still hold.
    static let maximumRestoredShare = 0.25

    /// Consecutive words the model and the captions share before they are
    /// trusted as the same passage. Shorter runs are also what two unrelated
    /// passages of one lecture share ("of the inner mitochondrial").
    static let anchorRun = 4
    /// Caption words in a row the model left out that are put back. The
    /// model drops a clause or a block where it lost its place, and removes
    /// shorter runs itself: false starts and fillers ("um, you know, kind
    /// of like") in spontaneous speech, where CS336's lectures showed up to
    /// six in a row.
    static let droppedRun = 7
    /// The model's words in a row that no caption says there before they
    /// are taken out as invented. An ASR mishearing it corrected is shorter.
    static let inventedRun = 10
    /// A shorter run is taken out when the model's text says it again close
    /// by: a sentence repeated at a block's or a chunk's edge.
    static let repeatedRun = 4
    static let repeatReach = 200
    /// How far a passage of `inventedRun` words or more is looked for again:
    /// the model repeats whole paragraphs from further back, and ten words
    /// in a row recur by chance far more rarely than four.
    static let repeatedPassageReach = 1_200
    /// Between two trusted runs, a stretch this long on both sides that
    /// shares under a third of the shorter one in runs of two or more is the
    /// model writing something else there: all of its text there is taken
    /// out, and all of the captions' put back. A caption side this long
    /// with under a third of it paired is dropped whole and put back whole.
    static let replacedStretch = 20
    /// A shared run shorter than this between two stretches that do not
    /// hold is taken as chance, and the three are judged as one.
    static let chanceRun = 8
    /// The model's words kept at an invented run's edge when a sentence end
    /// parts them from it.
    static let sentenceEdge = 3

    /// `formatted` held to what `raw` says, with `raw`'s markers set on it as
    /// `anchored` sets them: caption runs the model left out are put back
    /// where they were said (`droppedRun`), unless `restoringDroppedCaptions`
    /// is false because the model was asked to take some out (a podcast's ad
    /// reads); the model's runs no caption says there, invented or repeated,
    /// are taken out (`inventedRun`, `repeatedRun`); and a stretch where the
    /// model wrote something else is replaced by the captions' words
    /// (`replacedStretch`). Its other words, punctuation and headings are
    /// kept. A caption run put back is written as the captions write it,
    /// with a capital after a sentence end and no punctuation added: where
    /// the model dropped the start of a sentence it capitalised the rest, so
    /// a period there would land mid-sentence. A word of the model's that
    /// text taken out leaves opening a sentence gets a capital too.
    ///
    /// Nil when the text cannot be held to the captions: they carry no
    /// markers, share no words with it, or would need more than
    /// `maximumRestoredShare` of their words put back.
    static func checked(
        _ formatted: String,
        against raw: String,
        restoringDroppedCaptions: Bool
    ) -> Checked? {
        let captions = Self.captions(of: raw)
        guard captions.isTimed else { return nil }
        let text = self.formatted(formatted)
        let pairs = align(captions.words, text.words)
        guard !pairs.isEmpty else { return nil }
        let repair = Self.repair(pairs, captions: captions, text: text, restoring: restoringDroppedCaptions)
        let restoredWords = repair.restored.reduce(0) { $0 + $1.words.count }
        let removedWords = repair.removed.filter { $0 }.count
        guard Double(restoredWords) <= maximumRestoredShare * Double(captions.words.count) else { return nil }

        // The model's tokens that keep a word, and the caption runs put back
        // before each; a run belongs before the token whose word it precedes.
        let tokens = text.tokens
        var tokenKept = [Bool](repeating: false, count: tokens.count)
        for (word, token) in text.wordToken.enumerated() where !repair.removed[word] {
            tokenKept[token] = true
        }
        var insertions: [Int: [Range<Int>]] = [:]
        for run in repair.restored {
            let token = run.before < text.words.count ? text.wordToken[run.before] : tokens.count
            insertions[token, default: []].append(run.words)
        }
        var captionWordsOf: [Int: [Int]] = [:]
        for pair in repair.kept { captionWordsOf[text.wordToken[pair.formatted], default: []].append(pair.raw) }

        var output: [Token] = []
        var outputPairs: [(raw: Int, formatted: Int)] = []
        var outputIndex = [Int?](repeating: nil, count: tokens.count)
        var restoredRuns: [String] = []
        var afterRemoval = false
        for position in 0...tokens.count {
            for run in insertions[position] ?? [] {
                let block = captions.wordBlock[run.lowerBound]
                restoredRuns.append("\(captions.blocks[block].time ?? "0:00") +\(run.count)")
                let afterSentence = output.last.map { endsSentence($0.text) } ?? true
                // Each written word the run begins, with the run's words in
                // it; one begun before the run is the model's already.
                var pieces: [(piece: Int, words: [Int])] = []
                for word in run {
                    let piece = captions.wordPiece[word]
                    if pieces.last?.piece == piece {
                        pieces[pieces.count - 1].words.append(word)
                    } else if word == 0 || captions.wordPiece[word - 1] != piece {
                        pieces.append((piece, [word]))
                    }
                }
                for (index, piece) in pieces.enumerated() {
                    var written = captions.pieces[piece.piece]
                    if afterSentence, index == 0 { written = capitalized(written) }
                    for word in piece.words { outputPairs.append((word, output.count)) }
                    output.append(Token(text: written, words: parts(of: written)))
                }
            }
            guard position < tokens.count else { continue }
            guard tokenKept[position] else {
                afterRemoval = true
                continue
            }
            outputIndex[position] = output.count
            for word in captionWordsOf[position] ?? [] { outputPairs.append((word, output.count)) }
            var token = tokens[position]
            // Words taken out before it may leave the model's word opening
            // a sentence: "…state 3. We call the state 3, and this" keeps
            // "…state 3. And this".
            if afterRemoval, output.last.map({ endsSentence($0.text) }) ?? true {
                token.text = capitalized(token.text)
            }
            afterRemoval = false
            output.append(token)
        }

        // A heading stays before the model's word it came before. One inside
        // text taken out goes with it, and so does one whose section was all
        // taken out; one opening text taken out moves to the next word kept.
        var headings: [(position: Int, line: String)] = []
        for (position, line) in text.headings {
            guard position < tokens.count else {
                headings.append((output.count, line))
                continue
            }
            if !tokenKept[position], position > 0, !tokenKept[position - 1] { continue }
            guard let next = (position..<tokens.count).first(where: { tokenKept[$0] }),
                  let index = outputIndex[next],
                  !text.headings.contains(where: { $0.position > position && $0.position <= next })
            else { continue }
            headings.append((index, line))
        }

        // In the captions' order, each pair at or after the one before it.
        var ordered: [(raw: Int, formatted: Int)] = []
        for pair in outputPairs.sorted(by: { $0.raw < $1.raw }) where pair.formatted >= (ordered.last?.formatted ?? 0) {
            ordered.append(pair)
        }
        guard !ordered.isEmpty else { return nil }
        let removedRuns = repair.removedRuns.map { run in
            text.words[run].prefix(6).joined(separator: " ") + (run.count > 6 ? "… (\(run.count))" : "")
        }
        return Checked(
            text: layout(output, headings: headings, pairs: ordered, captions: captions),
            restoredWords: restoredWords,
            removedWords: removedWords,
            captionWords: captions.words.count,
            formattedWords: text.words.count,
            restored: restoredRuns,
            removed: removedRuns
        )
    }

    /// What the fidelity check changes: the model's words taken out, the
    /// alignment of the words kept, and the caption runs put back, each
    /// before the model's word at `before`.
    private struct Repair {
        var removed: [Bool]
        var removedRuns: [Range<Int>] = []
        var kept: [(raw: Int, formatted: Int)] = []
        var restored: [(words: Range<Int>, before: Int)] = []
    }

    /// The alignment read for what the model left out, added or wrote in
    /// place of what was said. Runs of `anchorRun` shared words are trusted,
    /// each grown over the same words either side of it; between two, the
    /// stretch of captions and of the model's text is judged by the words
    /// the alignment pairs inside it.
    private static func repair(
        _ pairs: [(raw: Int, formatted: Int)],
        captions: Captions,
        text: Formatted,
        restoring: Bool
    ) -> Repair {
        let a = captions.words
        let b = text.words
        var result = Repair(removed: [Bool](repeating: false, count: b.count))

        var anchors: [(raw: Int, formatted: Int, count: Int)] = [(0, 0, 0)]
        var run: (raw: Int, formatted: Int, count: Int) = (0, 0, 0)
        for pair in pairs {
            if run.count > 0, pair.raw == run.raw + run.count, pair.formatted == run.formatted + run.count {
                run.count += 1
                continue
            }
            if run.count >= anchorRun { anchors.append(run) }
            run = (pair.raw, pair.formatted, 1)
        }
        if run.count >= anchorRun { anchors.append(run) }
        anchors.append((a.count, b.count, 0))
        for index in 1..<anchors.count {
            var end = (raw: anchors[index - 1].raw + anchors[index - 1].count,
                       formatted: anchors[index - 1].formatted + anchors[index - 1].count)
            while end.raw < anchors[index].raw, end.formatted < anchors[index].formatted,
                  a[end.raw] == b[end.formatted] {
                anchors[index - 1].count += 1
                end = (end.raw + 1, end.formatted + 1)
            }
            while anchors[index].raw > end.raw, anchors[index].formatted > end.formatted,
                  a[anchors[index].raw - 1] == b[anchors[index].formatted - 1] {
                anchors[index].raw -= 1
                anchors[index].formatted -= 1
                anchors[index].count += 1
            }
        }

        /// The alignment's pairs inside a stretch.
        func paired(_ raw: Range<Int>, _ formatted: Range<Int>) -> [(raw: Int, formatted: Int)] {
            var low = 0
            var high = pairs.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[middle].raw < raw.lowerBound { low = middle + 1 } else { high = middle }
            }
            var found: [(raw: Int, formatted: Int)] = []
            while low < pairs.count, pairs[low].raw < raw.upperBound {
                if formatted.contains(pairs[low].formatted) { found.append(pairs[low]) }
                low += 1
            }
            return found
        }
        /// How many of a stretch's pairs have a neighbour: the words the two
        /// sides share in runs. Two passages of one lecture share single
        /// words by chance ("the", "membrane"), rarely two in a row.
        func coherent(_ inside: [(raw: Int, formatted: Int)]) -> Int {
            inside.indices.filter { index in
                (index > 0 && inside[index - 1].raw + 1 == inside[index].raw
                    && inside[index - 1].formatted + 1 == inside[index].formatted)
                    || (index + 1 < inside.count && inside[index].raw + 1 == inside[index + 1].raw
                        && inside[index].formatted + 1 == inside[index + 1].formatted)
            }.count
        }
        /// Whether one side of a stretch is long and shares too little with
        /// the other to be the same passage.
        func isLoose(_ raw: Range<Int>, _ formatted: Range<Int>) -> Bool {
            let longest = max(raw.count, formatted.count)
            return longest >= replacedStretch && coherent(paired(raw, formatted)) * 3 < longest
        }
        func end(_ anchor: (raw: Int, formatted: Int, count: Int)) -> (raw: Int, formatted: Int) {
            (anchor.raw + anchor.count, anchor.formatted + anchor.count)
        }

        // A short run between two loose stretches is what the model's text
        // there shares with the captions by chance ("of the inner
        // mitochondrial membrane", in a lecture on it); left in, it cuts one
        // stretch the model wrote in place of another into pieces too short
        // to judge.
        var trusted: [(raw: Int, formatted: Int, count: Int)] = []
        for anchor in anchors {
            trusted.append(anchor)
            while trusted.count >= 3 {
                let before = end(trusted[trusted.count - 3])
                let middle = trusted[trusted.count - 2]
                let after = trusted[trusted.count - 1]
                guard middle.count < chanceRun,
                      isLoose(before.raw..<middle.raw, before.formatted..<middle.formatted),
                      isLoose(end(middle).raw..<after.raw, end(middle).formatted..<after.formatted)
                else { break }
                trusted.remove(at: trusted.count - 2)
            }
        }

        for (index, anchor) in trusted.enumerated() {
            for offset in 0..<anchor.count { result.kept.append((anchor.raw + offset, anchor.formatted + offset)) }
            guard index + 1 < trusted.count else { break }
            let raw = end(anchor).raw..<trusted[index + 1].raw
            let formatted = end(anchor).formatted..<trusted[index + 1].formatted
            guard !raw.isEmpty || !formatted.isEmpty else { continue }
            var inside = paired(raw, formatted)

            // The model's side. Where both sides are long and share few
            // runs, the model wrote something else here (earlier paragraphs
            // again, in "Mitochondrial Cell Biology 2"), and all of it goes.
            // Otherwise each long run no caption says here goes, trimmed to
            // its sentences, and then any of the model's words stranded
            // between two such runs with too few shared to be a passage.
            let replaced = min(raw.count, formatted.count) >= replacedStretch
                && coherent(inside) * 3 < min(raw.count, formatted.count)
            if replaced {
                inside = []
                mark(formatted, removedIn: &result)
            } else {
                let shared = Set(inside.map(\.formatted))
                var removedHere = repeatedPassages(in: formatted, of: b)
                let repeated = Set(removedHere.joined())
                var start = formatted.lowerBound
                while start < formatted.upperBound {
                    guard !shared.contains(start), !repeated.contains(start) else { start += 1; continue }
                    var end = start
                    while end < formatted.upperBound, !shared.contains(end), !repeated.contains(end) { end += 1 }
                    if end - start >= inventedRun || (end - start >= repeatedRun && isRepeated(start..<end, in: b)) {
                        removedHere.append(sentences(of: start..<end, in: text))
                    }
                    start = end
                }
                removedHere.sort { $0.lowerBound < $1.lowerBound }
                var stranded: [Range<Int>] = []
                for (before, after) in zip(removedHere, removedHere.dropFirst()) {
                    let between = before.upperBound..<after.lowerBound
                    if between.filter({ shared.contains($0) }).count < anchorRun { stranded.append(between) }
                }
                for run in (removedHere + stranded).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    mark(run, removedIn: &result)
                }
                inside.removeAll { result.removed[$0.formatted] }
            }

            // The captions' side: between each two words kept, the caption
            // words neither pairs, put back when long, when so little of
            // this stretch is paired that it is all dropped, or when all the
            // model wrote in their place was taken out.
            if restoring, !raw.isEmpty {
                let restoresAll = replaced || (raw.count >= replacedStretch && inside.count * 3 < raw.count)
                if restoresAll, !replaced {
                    // The model's own words among the few it kept here are
                    // its rewording of what goes back ("This means that"
                    // for "we just have to keep in mind that").
                    let paired = Set(inside.map(\.formatted))
                    var start = formatted.lowerBound
                    while start < formatted.upperBound {
                        guard !paired.contains(start), !result.removed[start] else { start += 1; continue }
                        var end = start
                        while end < formatted.upperBound, !paired.contains(end), !result.removed[end] { end += 1 }
                        mark(start..<end, removedIn: &result)
                        start = end
                    }
                }
                var slot = (raw: raw.lowerBound, formatted: formatted.lowerBound)
                for index in 0...inside.count {
                    let end = index < inside.count ? inside[index] : (raw: raw.upperBound, formatted: formatted.upperBound)
                    let written = slot.formatted..<end.formatted
                    if end.raw > slot.raw,
                       restoresAll || end.raw - slot.raw >= droppedRun
                        || (!written.isEmpty && written.allSatisfy { result.removed[$0] }) {
                        result.restored.append((slot.raw..<end.raw, end.formatted))
                    }
                    slot = (end.raw + 1, end.formatted + 1)
                }
            }
            result.kept += inside
        }
        return result
    }

    /// An invented or repeated run less the words at either end that a
    /// sentence end parts from it, up to `sentenceEdge`: the model's
    /// "…in different cellular contexts. Cristae can vary" invents all but
    /// "Cristae", which opens the sentence it kept.
    private static func sentences(of run: Range<Int>, in text: Formatted) -> Range<Int> {
        let ends = run.filter { word in
            let token = text.wordToken[word]
            return (word + 1 == text.words.count || text.wordToken[word + 1] != token)
                && endsSentence(text.tokens[token].text)
        }
        guard let first = ends.first, let last = ends.last else { return run }
        var lower = run.lowerBound
        var upper = run.upperBound
        if first + 1 - lower <= sentenceEdge { lower = first + 1 }
        if upper - (last + 1) <= sentenceEdge { upper = last + 1 }
        return lower < upper ? lower..<upper : run
    }

    private static func mark(_ run: Range<Int>, removedIn repair: inout Repair) {
        guard !run.isEmpty else { return }
        for word in run { repair.removed[word] = true }
        if let last = repair.removedRuns.last, last.upperBound == run.lowerBound {
            repair.removedRuns[repair.removedRuns.count - 1] = last.lowerBound..<run.upperBound
        } else {
            repair.removedRuns.append(run)
        }
    }

    /// The stretches of `range`, `inventedRun` words or longer, that the
    /// model's text says again within `repeatedPassageReach` words: a
    /// passage written twice, whichever of its words the captions happen to
    /// share.
    private static func repeatedPassages(in range: Range<Int>, of words: [String]) -> [Range<Int>] {
        var passages: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var longest = 0
            for other in max(0, start - repeatedPassageReach)..<min(words.count, start + repeatedPassageReach)
            where other != start && words[other] == words[start] {
                var length = 0
                while start + length < range.upperBound, other + length < words.count,
                      length < abs(other - start), words[start + length] == words[other + length] {
                    length += 1
                }
                longest = max(longest, length)
            }
            guard longest >= inventedRun else {
                start += 1
                continue
            }
            if let last = passages.last, last.upperBound == start {
                passages[passages.count - 1] = last.lowerBound..<(start + longest)
            } else {
                passages.append(start..<(start + longest))
            }
            start += longest
        }
        return passages
    }

    /// Whether the model's text says `run` again within `repeatReach` words.
    private static func isRepeated(_ run: Range<Int>, in words: [String]) -> Bool {
        let lower = max(0, run.lowerBound - repeatReach)
        let upper = min(words.count - run.count, run.upperBound + repeatReach)
        guard lower <= upper else { return false }
        return (lower...upper).contains { start in
            abs(start - run.lowerBound) >= run.count
                && words[start..<(start + run.count)].elementsEqual(words[run])
        }
    }

    /// `text` with its first letter a capital.
    private static func capitalized(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    /// Whether a token closes a sentence: "cell.", "why?", "said.\u{201D}".
    private static func endsSentence(_ text: String) -> Bool {
        let closing: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}"]
        guard let last = text.reversed().first(where: { !closing.contains($0) }) else { return false }
        return ".!?".contains(last)
    }

    // MARK: Layout

    /// The tokens cut into one paragraph per caption block the pairs reach,
    /// each opening with the block's marker, and at each heading. `pairs`
    /// are caption words with the token each is in, in order.
    private static func layout(
        _ tokens: [Token],
        headings: [(position: Int, line: String)],
        pairs: [(raw: Int, formatted: Int)],
        captions: Captions
    ) -> String {
        let blocks = captions.blocks
        let rawBlock = captions.wordBlock

        // The blocks the model kept, in order, and the last token matched to
        // each: a block begins right after the one before it ends, so a word
        // the model added between two blocks opens the later one.
        var kept: [Int] = []
        var lastToken: [Int: Int] = [:]
        for pair in pairs {
            let block = rawBlock[pair.raw]
            if kept.last != block { kept.append(block) }
            lastToken[block] = pair.formatted
        }
        guard !kept.isEmpty else { return "" }
        var starts = [0]
        for block in kept.dropLast() { starts.append((lastToken[block] ?? 0) + 1) }

        // A heading stays where the model put it, at the topic's turn. One a
        // few words from a block's edge moves the edge to it instead, so no
        // sentence is split around the heading; the marker then opens a word
        // or two off, about a second. One further inside cuts the block's
        // paragraph there, and the words after it are timed by where they
        // fall in the block's captions, as a quote is (`LectureQuizTimeline`).
        var firstRaw: [Int: Int] = [:]
        var rawCount: [Int: Int] = [:]
        for (index, block) in rawBlock.enumerated() {
            if firstRaw[block] == nil { firstRaw[block] = index }
            rawCount[block, default: 0] += 1
        }
        let times = blocks.map { $0.time.flatMap(seconds(of:)) }
        func moment(at position: Int, in block: Int) -> String? {
            guard let start = times[block], let first = firstRaw[block], let count = rawCount[block],
                  let next = times[(block + 1)...].lazy.compactMap({ $0 }).first, next > start,
                  let raw = pairs.first(where: { $0.formatted >= position && rawBlock[$0.raw] == block })?.raw
                    ?? pairs.last(where: { $0.formatted < position && rawBlock[$0.raw] == block })?.raw
            else { return nil }
            return label(start + (next - start) * Double(raw - first) / Double(count))
        }
        var cuts: [(position: Int, block: Int, line: String)] = []
        var trailing: [String] = []
        for (position, line) in headings {
            guard let index = starts.indices.last(where: { starts[$0] <= position }), position < tokens.count else {
                trailing.append(line)
                continue
            }
            let end = index + 1 < starts.count ? starts[index + 1] : tokens.count
            if index > 0, position - starts[index] < minimumFragment {
                starts[index] = position
            } else if index + 1 < starts.count, position > starts[index], end - position < minimumFragment {
                starts[index + 1] = position
            }
            cuts.append((position, kept[index], line))
        }
        var paragraphs: [Int: (marker: String?, headings: [String])] = [:]
        for (index, block) in kept.enumerated() {
            paragraphs[starts[index]] = (blocks[block].time, [])
        }
        for cut in cuts {
            if paragraphs[cut.position] == nil { paragraphs[cut.position] = (moment(at: cut.position, in: cut.block), []) }
            paragraphs[cut.position]?.headings.append(cut.line)
        }

        let opened = paragraphs.keys.sorted()
        var parts: [String] = []
        for (index, start) in opened.enumerated() {
            let end = index + 1 < opened.count ? opened[index + 1] : tokens.count
            guard let paragraph = paragraphs[start], start < end else { continue }
            let text = tokens[start..<end].map(\.text).joined(separator: " ")
            let body = paragraph.marker.map { "[\($0)] \(text)" } ?? text
            parts.append((paragraph.headings + [body]).joined(separator: "\n"))
        }
        if !trailing.isEmpty { parts.append(trailing.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The longest line after a marker read as a heading: the model also
    /// writes "[12:12] ## Classical respiratory states How does one…", a
    /// heading run into its paragraph, which stays the paragraph's text.
    static let markedHeadingWords = 12

    /// Words between a heading and a block's edge below which the edge moves
    /// to the heading rather than cut a scrap of a sentence off.
    static let minimumFragment = 4

    /// `754` for "12:34", `3723` for "1:02:03".
    private static func seconds(of label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// A moment as the captions' markers write it: "12:34", "1:02:03".
    private static func label(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Reading

    /// The captions' blocks and words.
    private static func captions(of raw: String) -> Captions {
        var captions = Captions()
        captions.blocks = rawBlocks(raw)
        for (index, block) in captions.blocks.enumerated() {
            for piece in block.text.split(whereSeparator: \.isWhitespace) {
                let words = parts(of: String(piece))
                guard !words.isEmpty else { continue }
                captions.pieces.append(String(piece))
                for word in words {
                    captions.words.append(word)
                    captions.wordBlock.append(index)
                    captions.wordPiece.append(captions.pieces.count - 1)
                }
            }
        }
        return captions
    }

    /// The caption text between markers, each block with the marker before
    /// it; the text before the first marker has none.
    private static func rawBlocks(_ raw: String) -> [(time: String?, text: String)] {
        let text = raw as NSString
        var blocks: [(time: String?, text: String)] = []
        var time: String?
        var cursor = 0
        for match in marker.matches(in: raw, range: NSRange(location: 0, length: text.length)) {
            blocks.append((time, text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            time = text.substring(with: match.range(at: 1))
            cursor = match.range.location + match.range.length
        }
        blocks.append((time, text.substring(from: cursor)))
        return blocks
    }

    /// The formatted text's words, its markers (and `unreadMarker`) taken
    /// out and punctuation standing alone kept with the word before it on
    /// its line, and its heading lines with the number of words before
    /// each. A short heading the model wrote after a marker ("[0:32] ##
    /// Overview") is a heading too.
    private static func formatted(_ formatted: String) -> Formatted {
        var text = Formatted()
        var leading = ""
        for line in formatted.components(separatedBy: .newlines) {
            let unmarked = marker.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line), withTemplate: " "
            )
            .replacingOccurrences(of: unreadMarker, with: " ")
            .trimmingCharacters(in: .whitespaces)
            let pieces = unmarked.split(whereSeparator: \.isWhitespace)
            let startsAsHeading = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            if heading.firstMatch(in: unmarked, range: NSRange(unmarked.startIndex..<unmarked.endIndex, in: unmarked)) != nil,
               startsAsHeading || pieces.count <= markedHeadingWords {
                text.headings.append((text.tokens.count, pieces.joined(separator: " ")))
                continue
            }
            var lineHasWord = false
            for piece in pieces {
                let written = String(piece)
                let words = parts(of: written)
                if !words.isEmpty {
                    text.tokens.append(Token(text: leading + written, words: words))
                    leading = ""
                    lineHasWord = true
                } else if lineHasWord {
                    text.tokens[text.tokens.count - 1].text += " " + written
                } else {
                    leading += written + " "
                }
            }
        }
        if !leading.isEmpty, !text.tokens.isEmpty {
            text.tokens[text.tokens.count - 1].text += " " + leading.trimmingCharacters(in: .whitespaces)
        }
        for (index, token) in text.tokens.enumerated() {
            for word in token.words {
                text.words.append(word)
                text.wordToken.append(index)
            }
        }
        return text
    }

    /// A word as it is compared: the letters and digits of each part
    /// `joiners` separate, lower case.
    private static func parts(of text: String) -> [String] {
        text.split(whereSeparator: { joiners.contains($0) }).map { folded(String($0)) }.filter { !$0.isEmpty }
    }

    private static func folded(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    // MARK: Alignment

    /// The caption words and formatted words that are the same words, as
    /// index pairs in order: the longest run of words the two share, found a
    /// window at a time. Each window aligns `alignmentWindow` caption words
    /// with half as many again formatted ones, room for what the model
    /// repeated; its first three quarters are kept and the rest aligned
    /// again with what follows. A window where nothing matches is caption
    /// text the model left out, and is passed over.
    private static func align(_ raw: [String], _ formatted: [String]) -> [(raw: Int, formatted: Int)] {
        // Words compared as numbers: a window compares hundreds of thousands of pairs.
        var ids: [String: Int] = [:]
        var a: [Int] = []
        a.reserveCapacity(raw.count)
        for word in raw {
            if let known = ids[word] {
                a.append(known)
            } else {
                ids[word] = ids.count
                a.append(ids.count - 1)
            }
        }
        let b = formatted.map { ids[$0] ?? -1 }
        var pairs: [(raw: Int, formatted: Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            let rawEnd = min(a.count, i + alignmentWindow)
            let formattedEnd = min(b.count, j + alignmentWindow + alignmentWindow / 2)
            let reachesEnd = rawEnd == a.count && formattedEnd == b.count
            let horizon = reachesEnd ? a.count : i + alignmentWindow * 3 / 4
            let matched = longestCommonRun(a, i..<rawEnd, b, j..<formattedEnd).filter { $0.raw < horizon }
            if let last = matched.last {
                pairs += matched
                i = last.raw + 1
                j = last.formatted + 1
            } else if reachesEnd {
                break
            } else {
                i = min(a.count, i + alignmentWindow / 2)
            }
        }
        return pairs
    }

    /// The pairs of one longest common subsequence of two stretches.
    private static func longestCommonRun(
        _ a: [Int], _ aRange: Range<Int>, _ b: [Int], _ bRange: Range<Int>
    ) -> [(raw: Int, formatted: Int)] {
        let n = aRange.count
        let m = bRange.count
        guard n > 0, m > 0 else { return [] }
        let width = m + 1
        var table = [UInt16](repeating: 0, count: (n + 1) * width)
        for x in stride(from: n - 1, through: 0, by: -1) {
            for y in stride(from: m - 1, through: 0, by: -1) {
                table[x * width + y] = a[aRange.lowerBound + x] == b[bRange.lowerBound + y]
                    ? table[(x + 1) * width + y + 1] + 1
                    : max(table[(x + 1) * width + y], table[x * width + y + 1])
            }
        }
        var pairs: [(raw: Int, formatted: Int)] = []
        var x = 0
        var y = 0
        while x < n, y < m {
            if a[aRange.lowerBound + x] == b[bRange.lowerBound + y] {
                pairs.append((aRange.lowerBound + x, bRange.lowerBound + y))
                x += 1
                y += 1
            } else if table[(x + 1) * width + y] >= table[x * width + y + 1] {
                x += 1
            } else {
                y += 1
            }
        }
        return pairs
    }
}

// MARK: - Errors

enum YouTubeTranscriptError: LocalizedError {
    case invalidURL
    case fetchFailed
    case rateLimited
    case parsingFailed(String)
    case noTranscriptAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid YouTube URL"
        case .fetchFailed:
            return "Failed to fetch YouTube page"
        case .rateLimited:
            return "YouTube rate limited the caption request. Try again in a moment."
        case .parsingFailed(let detail):
            return "Failed to parse YouTube data: \(detail)"
        case .noTranscriptAvailable:
            return "No transcript available for this video. The video may not have captions enabled."
        }
    }
}
