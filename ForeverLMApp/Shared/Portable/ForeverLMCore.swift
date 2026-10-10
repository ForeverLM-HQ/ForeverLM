#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// A clipboard-friendly rendering of a learner's visible conversation. Callers
/// decide which messages are user-facing before constructing the turns, keeping
/// tool protocol and other operational rows out of copied transcripts.
struct ConversationTranscriptFormatter {
    enum Speaker {
        case user
        case assistant

        var label: String {
            switch self {
            case .user: return "You"
            case .assistant: return "ForeverLM"
            }
        }
    }

    struct Turn {
        let speaker: Speaker
        let content: String
    }

    static func plainText(from turns: [Turn]) -> String {
        turns.compactMap { turn in
            var content = turn.content[...]
            while content.first?.isWhitespace == true { content.removeFirst() }
            while content.last?.isWhitespace == true { content.removeLast() }
            guard !content.isEmpty else { return nil }
            return "\(turn.speaker.label):\n\(content)"
        }
        .joined(separator: "\n\n")
    }
}

/// Pure domain behavior shared by the Apple apps and the browser WebAssembly
/// module. Keep platform services (SQLite, CloudKit, files, UI, and networking)
/// outside this boundary so the same source can compile for macOS, iOS, and WASI.
public enum ForeverLMCore {
    public static let wholeSourceReviewBaseIntervalDays = 2.0
    public static let wholeSourceReviewGrowthFactor = 2.2
    public static let wholeSourceReviewMaximumIntervalDays = 180.0
    public static let wholeSourceFirstReviewDelayDays = 1.0

    /// The memory review's source ladder, in days, indexed by rung. A source
    /// climbs one rung when a free recall produces most of its ideas, holds
    /// when it does not, and skips a rung after two near-complete recalls in a
    /// row. Capped at the last entry so a well-known source keeps resurfacing
    /// twice a year rather than falling out of rotation.
    public static let memoryReviewLadderDays: [Int] = [1, 3, 7, 21, 60, 180]
    /// Fraction of a source's ideas that must come back unaided to advance.
    public static let memoryReviewAdvanceFraction = 0.7
    /// Fraction at or above which two consecutive recalls skip a rung.
    public static let memoryReviewSkipFraction = 0.9

    public static func canonicalSourceType(_ sourceType: String) -> String {
        let normalized = trimmingWhitespace(sourceType).lowercased()

        switch normalized {
        case "manual", "unclassified":
            return "article"
        default:
            return normalized
        }
    }

    public static func youtubeVideoID(from value: String) -> String? {
        let trimmed = trimmingWhitespace(value)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let rawHost = components.host?.lowercased()
        else { return nil }

        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        if host == "youtu.be" {
            return components.path
                .split(separator: "/")
                .first
                .map(String.init)
                .flatMap(validYouTubeVideoID)
        }

        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if components.path == "/watch",
           let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return validYouTubeVideoID(videoID)
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count >= 2,
              ["embed", "shorts", "live", "v"].contains(pathParts[0].lowercased())
        else { return nil }
        return validYouTubeVideoID(pathParts[1])
    }

    public static func youtubeThumbnailURL(for value: String) -> String? {
        guard let videoID = youtubeVideoID(from: value) else { return nil }
        return "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
    }

    public static func youtubeEmbedURL(for value: String) -> String? {
        guard let videoID = youtubeVideoID(from: value) else { return nil }
        return "https://www.youtube-nocookie.com/embed/\(videoID)"
    }

    public static func isZoomRecordingURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: trimmingWhitespace(value)),
              let host = components.host?.lowercased(),
              host == "zoom.us" || host.hasSuffix(".zoom.us")
        else { return false }
        let path = components.path.lowercased()
        return path.contains("/rec/play/") || path.contains("/rec/share/")
            || path.contains("/recording/play/") || path.contains("/recording/share/")
    }

    /// The recurring meeting series a Zoom cloud recording belongs to, as a
    /// stable group id and the title that group starts life with.
    ///
    /// A Zoom share link carries no series of its own. The token is per
    /// recording, the play API's `meetingId` is per occurrence, and the
    /// recording's `topic` is whatever the host typed for that sitting — a talk
    /// title (`Flux Matching: Generative modeling with…`) at least as often as
    /// the name of the series it belongs to. The one durable fact every
    /// occurrence of a recurring meeting shares is the Zoom account that hosted
    /// it, which is right there in the link, so that account is the series, and
    /// the learner renames the row to whatever the seminar is really called.
    ///
    /// Deterministic on purpose, for the same reason a Drive folder id is the
    /// identity boundary there: two Macs migrating the same library have to
    /// land on one group id, or sync turns one series into two. It also means
    /// nothing here can be decided by a model — a grouping key never is.
    public static func zoomMeetingSeries(forRecordingURL value: String) -> (id: String, title: String)? {
        guard isZoomRecordingURL(value),
              let host = URLComponents(string: trimmingWhitespace(value))?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return (id: "zoom:\(host)", title: host)
    }

    /// The same source-family tab routing used by the native sidebar and Web
    /// Studio.
    ///
    /// Every meeting routes to one `meetings` tab whatever provider it came
    /// from. Provider used to pick between `read-ai` and `google-drive` here,
    /// which made a presentation split out of a fact about the session and left
    /// locally imported folders with no tab at all. It is now a badge and a
    /// filter on the row, read from `discoveryOrigin` at the point of display.
    ///
    /// Zoom joined them: a cloud recording of a call is a meeting, so it is
    /// typed `meeting` at ingest and routed by that type like every other
    /// provider. This used to re-read the URL shape to fork `video` into a
    /// separate `zoom` tab, which is why a Zoom recording could never sit in
    /// the series it was an occurrence of. A recording synced from a build that
    /// still stored it as a `video` is caught by the URL check below, so it
    /// lands in Meetings rather than among YouTube videos.
    ///
    /// `discoveryOrigin` stays in the signature even though no arm reads it any
    /// more: the browser calls this positionally through the WASM bridge, so
    /// dropping it would break `foreverlm-core-wasm.js` for no gain.
    public static func sourceTabID(
        sourceType: String,
        discoveryOrigin: String? = nil,
        url: String? = nil
    ) -> String {
        switch canonicalSourceType(sourceType) {
        case "meeting":
            return "meetings"
        case "video":
            return url.map(isZoomRecordingURL) == true ? "meetings" : "video"
        case let type:
            return type
        }
    }

    /// One cross-platform rule for whether a source owns the durable `readAt`
    /// state. Native readers already know whether their resolved source is a web
    /// article; browser callers can use the URL overload below. Keeping the type
    /// gate here prevents a web client from writing read state that native UI can
    /// never represent for books, media, or plugin records.
    public static func supportsReadTracking(sourceType: String, isWebArticle: Bool) -> Bool {
        if ownsReadStateAnywhere(sourceType: sourceType) { return true }
        guard isWebArticle else { return false }
        switch trimmingWhitespace(sourceType).lowercased() {
        case "article", "manual", "unclassified":
            return true
        default:
            return false
        }
    }

    /// Types that own read state wherever their text lives. A paper is normally a
    /// local PDF rather than a web article, so it would never clear the shape
    /// checks that gate the article family — yet both clients show it a read mark.
    private static func ownsReadStateAnywhere(sourceType: String) -> Bool {
        trimmingWhitespace(sourceType).lowercased() == "paper"
    }

    /// Browser convenience overload. Only an explicit HTTP(S) URL is a web
    /// article; relative Web Imports and local file identities are not.
    public static func supportsReadTracking(
        sourceType: String,
        url: String?,
        hasLocalFile: Bool = false,
        isArchivedArticle: Bool = false,
        isPDF: Bool = false
    ) -> Bool {
        if ownsReadStateAnywhere(sourceType: sourceType) { return true }
        guard let url,
              let components = URLComponents(string: trimmingWhitespace(url)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        guard !isPDF, !hasLocalFile || isArchivedArticle else { return false }
        return supportsReadTracking(sourceType: sourceType, isWebArticle: true)
    }

    /// Cross-platform spaced-repetition interval for a completed whole-source
    /// review. The loop stops once the capped result is reached, so a corrupt
    /// review count cannot create unbounded work in either client.
    public static func wholeSourceReviewIntervalDays(
        reviewCount: Int,
        lastScore: Double?
    ) -> Double {
        let scoreFactor: Double
        switch lastScore {
        case .some(let score) where score.isFinite && score >= 0.8:
            scoreFactor = 1.6
        case .some(let score) where score.isFinite && score >= 0.6:
            scoreFactor = 1.0
        case .some(let score) where score.isFinite:
            scoreFactor = 0.5
        case .some, .none:
            scoreFactor = 1.0
        }

        var growth = 1.0
        var repetitions = max(0, reviewCount - 1)
        while repetitions > 0,
              wholeSourceReviewBaseIntervalDays * growth * scoreFactor
                < wholeSourceReviewMaximumIntervalDays {
            growth *= wholeSourceReviewGrowthFactor
            repetitions -= 1
        }
        let interval = wholeSourceReviewBaseIntervalDays * growth * scoreFactor
        return min(max(1, interval), wholeSourceReviewMaximumIntervalDays)
    }

    public static func wholeSourceReviewDueAtMilliseconds(
        lastReviewedAtMilliseconds: Double,
        reviewCount: Int,
        lastScore: Double?
    ) -> Double? {
        guard lastReviewedAtMilliseconds.isFinite else { return nil }
        return lastReviewedAtMilliseconds
            + wholeSourceReviewIntervalDays(reviewCount: reviewCount, lastScore: lastScore)
                * 86_400_000
    }

    public static func wholeSourceFirstReviewDueAtMilliseconds(
        consumedAtMilliseconds: Double
    ) -> Double? {
        guard consumedAtMilliseconds.isFinite else { return nil }
        return consumedAtMilliseconds + wholeSourceFirstReviewDelayDays * 86_400_000
    }

    /// The rung a source stands on after a chronological run of contour
    /// recalls, each given as the fraction of its ideas produced unaided.
    ///
    /// ≥ `memoryReviewAdvanceFraction` climbs one rung; below it holds; two
    /// consecutive recalls at or above `memoryReviewSkipFraction` climb two.
    /// A `nil` fraction is a recall whose question was judged ambiguous: it
    /// moves nothing and breaks a skip streak, so a bad question costs one
    /// turn and never a schedule. The rung never exceeds the ladder's top.
    public static func memoryReviewRung(producedFractions: [Double?]) -> Int {
        var rung = 0
        var previousWasNearComplete = false
        let top = max(0, memoryReviewLadderDays.count - 1)
        for fraction in producedFractions {
            guard let fraction, fraction.isFinite else {
                previousWasNearComplete = false
                continue
            }
            if fraction >= memoryReviewAdvanceFraction {
                let nearComplete = fraction >= memoryReviewSkipFraction
                rung += (nearComplete && previousWasNearComplete) ? 2 : 1
                previousWasNearComplete = nearComplete
            } else {
                previousWasNearComplete = false
            }
            rung = min(rung, top)
        }
        return rung
    }

    /// Days until a source on `rung` is due again.
    public static func memoryReviewIntervalDays(rung: Int) -> Int {
        guard !memoryReviewLadderDays.isEmpty else { return 1 }
        return memoryReviewLadderDays[min(max(0, rung), memoryReviewLadderDays.count - 1)]
    }

    private static func validYouTubeVideoID(_ value: String) -> String? {
        let trimmed = trimmingWhitespace(value)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              })
        else { return nil }
        return trimmed
    }

    private static func trimmingWhitespace(_ value: String) -> String {
        var trimmed = value[...]
        while trimmed.first?.isWhitespace == true { trimmed.removeFirst() }
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        return String(trimmed)
    }
}

/// How far the learner has scrolled through a web article (live page or archived
/// HTML), JSON-encoded into `sources.reading_position_locator` — the same slot
/// the EPUB and video readers use — so it rides the existing source sync round
/// trip and feeds the "In progress" read filter with no schema change. The key
/// name is unique so EPUB/video locators can never decode as an article position
/// (and vice versa). The fraction is rounded so repeated saves of the same
/// position encode to identical strings, which the persistence layer dedupes.
public struct ArticleReadingPositionLocator: Codable, Equatable {
    public let webScrollFraction: Double

    public init(scrollFraction: Double) {
        let clamped = min(max(scrollFraction, 0), 1)
        self.webScrollFraction = (clamped * 10_000).rounded() / 10_000
    }

    public init?(encoded: String?) {
        guard let encoded,
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.webScrollFraction.isFinite else { return nil }
        self = Self(scrollFraction: decoded.webScrollFraction)
    }

    public var encoded: String? {
        guard webScrollFraction.isFinite,
              let data = try? JSONEncoder().encode(self)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A Notebook's short card description, in the one stored form every client
/// writes: whitespace runs (line breaks included) collapse to a single space,
/// the ends are trimmed, the length is capped, and an empty result is nil so
/// "no description" is one value everywhere. The Mac's store, the phone's
/// CloudKit mutation and the MCP tools all normalise through here, so a
/// summary written on one device reads back the same on the others.
public enum NotebookSummary {
    /// Longest stored summary; room for two card lines, not a paragraph.
    public static let maxLength = 200

    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }
}

/// What a companion `LearningGoal` record is: a notebook, a Goal,
/// or neither (goals-design.md; Mac schema 120). The deadline is the
/// discriminator, not the parent: a companion record with no real deadline and
/// no parent is a notebook, and one with a real deadline is a Goal, tagged to a
/// notebook (`parentNotebookID`) or standing on its own. "No real deadline" is
/// an `endAt` at or past `openEndedThresholdReferenceSeconds`; every client
/// stores `openEndedEndAtReferenceSeconds` for one.
///
/// The Mac's `LearningGoalRecord` answers `isOpenEnded`, `isNotebook` and
/// `isGoal` through here and the phone reads its CloudKit payloads through
/// here, so the two cannot disagree about a record again: the phone's own rule
/// was "any parentless companion record" until 2026-10-02, which listed a
/// Mac's standalone Goals as notebooks, while the notebooks it created carried
/// a 30-day deadline and were Goals on every Mac. `library-core.js`
/// (`learningGoalIsNotebook`) carries the rule for Web Studio and
/// `hosted-projection.ts` for hosted MCP.
///
/// Dates are Foundation reference-date seconds, which is what `JSONEncoder`
/// writes for a `Date` in the payload and what the Mac reads back, so the
/// rule needs no Foundation and a payload is judged by its raw `endAt`.
public enum LearningGoalShape {
    public static let companionKind = "companion"
    /// 2100-01-01 00:00 UTC (Unix 4 102 444 800): the `endAt` a notebook is
    /// stored with, so every surface reads it as "no deadline".
    public static let openEndedEndAtReferenceSeconds: Double = 3_124_137_600
    /// Unix 4 000 000 000 (2096): an `endAt` at or past this is open-ended.
    public static let openEndedThresholdReferenceSeconds: Double = 3_021_692_800

    public static func isOpenEnded(kind: String?, endAtReferenceSeconds: Double) -> Bool {
        kind == companionKind && endAtReferenceSeconds >= openEndedThresholdReferenceSeconds
    }

    /// Whether a parent notebook is named at all; blank reads as none.
    public static func namesParentNotebook(_ parentNotebookID: String?) -> Bool {
        (parentNotebookID ?? "").contains { !$0.isWhitespace && !$0.isNewline }
    }

    /// A notebook: an open-ended companion record with no parent.
    public static func isNotebook(kind: String?, parentNotebookID: String?, endAtReferenceSeconds: Double) -> Bool {
        isOpenEnded(kind: kind, endAtReferenceSeconds: endAtReferenceSeconds)
            && !namesParentNotebook(parentNotebookID)
    }

    /// A Goal: a companion record with a real deadline, parented or not.
    public static func isGoal(kind: String?, endAtReferenceSeconds: Double) -> Bool {
        kind == companionKind && !isOpenEnded(kind: kind, endAtReferenceSeconds: endAtReferenceSeconds)
    }
}

/// The GitHub repository a Notebook is about, in the one stored form every
/// client writes: canonical `owner/repo`. Accepts what a learner types or
/// pastes — `owner/repo`, `owner/repo.git`, or a github.com URL with or without
/// a scheme or `www.` whose path may continue past the repository
/// (`https://github.com/owner/repo/tree/main`) — and answers nil for anything
/// that does not name a repository. Owner and repository names follow GitHub's
/// own rules: an owner is 1–39 alphanumerics or hyphens not starting with a
/// hyphen, a repository 1–100 of alphanumerics, `.`, `_` and `-`. Case is kept
/// as typed; GitHub treats names case-insensitively and echoes the canonical
/// spelling in its answers. The Mac store, the phone's payload reader and the
/// MCP tools all normalise through here; `library-core.js` carries the same
/// rule for Web Studio.
public enum GitHubRepositoryName {
    public static func normalized(_ raw: String?) -> String? {
        // Portable: no Foundation here, so the trim is by hand rather than
        // `trimmingCharacters`, which the WebAssembly build has no member for.
        var text = raw ?? ""
        while text.first?.isWhitespace == true { text.removeFirst() }
        while text.last?.isWhitespace == true { text.removeLast() }
        guard !text.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        for host in ["www.github.com/", "github.com/"] where text.lowercased().hasPrefix(host) {
            text.removeFirst(host.count)
        }
        // Anything after a query or fragment belongs to the page, not the name.
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        let owner = String(components[0])
        var repo = String(components[1])
        if repo.lowercased().hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard isValidOwner(owner), isValidRepository(repo) else { return nil }
        return "\(owner)/\(repo)"
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
    }

    private static func isValidOwner(_ owner: String) -> Bool {
        guard (1...39).contains(owner.count), let first = owner.unicodeScalars.first, first != "-" else { return false }
        return owner.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
    }

    private static func isValidRepository(_ repo: String) -> Bool {
        guard (1...100).contains(repo.count), repo != ".", repo != ".." else { return false }
        return repo.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
}
