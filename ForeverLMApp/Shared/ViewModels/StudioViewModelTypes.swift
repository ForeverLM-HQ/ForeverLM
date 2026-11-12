import CoreGraphics
import Foundation

enum StudioExpandedPanel: String {
    case sources
    case reader
    case search
}

/// Filter applied to the Review Sessions panel. `.source` filters to a single
/// source; `.group` filters to any source whose `parentGroup` matches (e.g.
/// every chapter of a book or every item in a course).
enum ReviewSessionFilter: Equatable {
    case source(String)
    case group(String)
}

/// The notebook a window's Sources list marks and adds to: the one that
/// window holds (`StudioWindowState.notebook`), while it is an active
/// notebook of the open library (`StudioViewModel.sidebarNotebook(in:)`).
struct SidebarNotebook: Equatable {
    let notebookID: String
    let title: String
}

/// How much of a Sources row a notebook holds. A source is in or out; a book
/// cover stands for its chapters, so it can be partly in.
enum NotebookMembershipState: Equatable {
    case none
    case some
    case all

    /// `rowIDs` named as the Sources list names them, against a notebook's
    /// members named the same way (`canonicalSourceID`).
    init(rowIDs: [String], members: Set<String>) {
        let inCount = rowIDs.reduce(0) { $0 + (members.contains($1) ? 1 : 0) }
        if inCount == 0 {
            self = .none
        } else {
            self = inCount == rowIDs.count ? .all : .some
        }
    }
}

enum SourceReviewFilter: String, CaseIterable {
    case all
    case reviewed
    case notReviewed

    var title: String {
        switch self {
        case .all: return "All"
        case .reviewed: return "Reviewed"
        case .notReviewed: return "Not Reviewed"
        }
    }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .reviewed: return "checkmark.circle"
        case .notReviewed: return "circle"
        }
    }
}

/// The visible completion status for a readable source. `readAt` remains the
/// whole-source read signal used by review intake, while the
/// Schedule activity ledger tells us whether that consumption was listening or
/// reading. A manual completion with no activity provenance stays Read.
///
/// This is the one status a source row draws. A review draws no badge of its
/// own (product owner, 2026-09-29); the Review filter and the row's Review Sessions
/// menu still find reviewed sources.
enum SourceConsumptionStatus: Equatable {
    case unread
    case listened
    case read

    init(isConsumed: Bool, completedActivityKinds: Set<SourceActivityKind>) {
        guard isConsumed else {
            self = .unread
            return
        }
        self = completedActivityKinds.contains(.listening)
            && !completedActivityKinds.contains(.reading)
            ? .listened
            : .read
    }

    var title: String {
        switch self {
        case .unread: return "Unread"
        case .listened: return "Listened"
        case .read: return "Read"
        }
    }

    var icon: String {
        switch self {
        case .unread: return "circle"
        case .listened: return "headphones"
        case .read: return "book.closed.fill"
        }
    }
}

/// How far the learner is through a course. A course is finished when its
/// lectures are, so only lecture videos count while the course has any:
/// optional papers and materials would otherwise keep a watched course from
/// ever reading as done. A course built only from readings counts every
/// lecture item instead.
struct CourseProgress: Equatable {
    struct Item: Equatable {
        var isLectureVideo: Bool
        /// Watched to the end, marked read, or reviewed.
        var isFinished: Bool
        /// Finished, or carrying a saved watch or reading position.
        var isStarted: Bool
    }

    let finished: Int
    let started: Int
    let total: Int
    let countsLectureVideos: Bool

    init(items: [Item]) {
        let videos = items.filter(\.isLectureVideo)
        let counted = videos.isEmpty ? items : videos
        finished = counted.filter(\.isFinished).count
        started = counted.filter { $0.isFinished || $0.isStarted }.count
        total = counted.count
        countsLectureVideos = !videos.isEmpty
    }

    var isComplete: Bool { total > 0 && finished == total }
    var isStarted: Bool { started > 0 }

    var fractionFinished: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }

    var summary: String {
        let noun = countsLectureVideos
            ? (total == 1 ? "lecture" : "lectures")
            : (total == 1 ? "item" : "items")
        if isComplete {
            return total == 1 ? "Finished" : "All \(total) \(noun) finished"
        }
        return "\(finished) of \(total) \(noun) finished"
    }
}

/// Filters sources by reading/consumption state. "Read" and "Listened" use
/// their distinct activity provenance; "In Progress" means a saved reading
/// position without a completed consumption signal.
enum SourceReadFilter: String, CaseIterable {
    case all
    case unread
    case inProgress
    case listened
    case read

    var title: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .inProgress: return "In Progress"
        case .listened: return "Listened"
        case .read: return "Read"
        }
    }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .unread: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .listened: return "headphones"
        case .read: return "circle.fill"
        }
    }
}

/// Filters sources by content/processing status.
enum SourceContentFilter: String, CaseIterable {
    case all
    case ready
    case processing
    case failed
    case paywalled

    var title: String {
        switch self {
        case .all: return "All"
        case .ready: return "Ready"
        case .processing: return "Processing"
        case .failed: return "Failed"
        case .paywalled: return "Paywalled"
        }
    }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .ready: return "checkmark.seal"
        case .processing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .paywalled: return "lock"
        }
    }
}

struct SourceSearchBestMatch: Equatable, Hashable {
    let sourceId: String
    let chunkId: String
    let query: String
    let excerpt: String
    let passage: String
    let findQuery: String
    let score: Float

    var presentationKey: String {
        "\(sourceId)|\(chunkId)|\(query)|\(findQuery)"
    }
}

struct SourceSearchResult {
    let article: StudioArticle
    let score: Float
    let bestMatch: SourceSearchBestMatch?
}

/// Where in a meeting session's document the reader should land, set by a click
/// on one of the session's artifact rows in the sidebar.
///
/// A session's files are not separate sources: the import merges each one's text
/// into a single document under its own `## Transcript` / `## Notes` / `## Chat`
/// heading. So opening "Notes" is a scroll inside the document the reader is
/// already showing, not a different document to load.
///
/// `subheading` and `anchorText` are the section's own first heading and first
/// paragraph, carried along because the section heading itself is not always
/// findable in the rendered document: a Gemini notes Doc opens with a heading of
/// its own (`### Quick notes`), which takes the place of the `## Notes` heading
/// before any paragraph is emitted. The revision makes a second click on the same
/// row a fresh request rather than an unchanged value the reader ignores.
struct MeetingSectionReaderTarget: Equatable, Sendable {
    let sourceID: String
    let kind: MeetingArtifactKind
    let subheading: String?
    let anchorText: String?
    let revision: UInt

    var presentationKey: String {
        "\(sourceID)|\(kind.rawValue)|\(revision)"
    }
}

/// A moment in a timed source that a chat citation or deep link asked the
/// reader to open at — `foreverlm://source/<id>?t=754` — consumed by whichever
/// reader shows that source: the YouTube and recording readers seek their
/// player and move the playhead, a transcript with no player scrolls to the
/// segment spoken at that time. The revision makes the same moment cited twice
/// two requests, so a second click on the same marker seeks again.
struct ReaderTimeTarget: Equatable, Sendable {
    let sourceID: String
    let seconds: Double
    let revision: UInt
    /// Whether the player plays from the moment, as a citation's click does,
    /// or holds there paused, as a walkthrough step does.
    var plays: Bool = true
    /// The Studio window whose Reader the request is for (`ReaderRequestWindow`);
    /// nil reaches a Reader in any window.
    var windowID: UUID? = nil

    var presentationKey: String {
        "\(sourceID)|\(seconds)|\(revision)"
    }
}

/// Which Reader a request to show a place in a source reaches: a passage to
/// flash, a moment to seek to, a figure to outline. A request made for one
/// window names it, and a Reader showing the same source in another window
/// leaves it alone (product owner, 2026-11-08, of a chat pointing at a passage
/// that jumped the same paper in the other window's Reader too: "it still opens
/// a paper reader in BOTH foreverlm windows"). A request naming no window, and a
/// Reader in no Studio window (a popped-out Reader), keep reaching each other.
enum ReaderRequestWindow {
    static func reaches(_ requestWindowID: UUID?, readerIn readerWindowID: UUID?) -> Bool {
        guard let requestWindowID, let readerWindowID else { return true }
        return requestWindowID == readerWindowID
    }
}

/// A chat asking the video Reader showing `sourceID` to pause, because the
/// learner started typing a question about it (docs/chat-design.md, "A
/// question beside a video is asked at its moment"). Spent by that Reader; the
/// revision makes a second question a second request.
struct ReaderVideoPauseRequest: Equatable, Sendable {
    let sourceID: String
    let revision: UInt
}

/// A passage in a text source that a chat citation asked the reader to show —
/// the excerpt the assistant copied from the source when it wrote the link —
/// consumed by whichever reader shows that source: the PDF, web and text
/// readers scroll to the passage and flash it. The mark is transient and
/// nothing like a saved highlight: it is never stored, never listed, and fades
/// on its own. The revision makes the same passage cited twice two requests,
/// so a second click on the same marker flashes again.
struct ReaderPassageTarget: Equatable, Sendable {
    let sourceID: String
    /// The words to find and flash; nil for a citation that names only a page.
    let passage: String?
    /// The page the citation names (`?page=N`), one-based and counted within
    /// the source's own pages. A PDF reader opens it when the passage is not
    /// found, or when there is no passage; readers without pages ignore it.
    let page: Int?
    let revision: UInt
    /// The Studio window whose Reader the request is for (`ReaderRequestWindow`);
    /// nil reaches a Reader in any window.
    let windowID: UUID?

    init(sourceID: String, passage: String?, page: Int? = nil, revision: UInt, windowID: UUID? = nil) {
        self.sourceID = sourceID
        self.passage = passage
        self.page = page
        self.revision = revision
        self.windowID = windowID
    }

    var presentationKey: String {
        "\(sourceID)|\(revision)"
    }
}

/// Where a walkthrough step points in a paper's PDF, for the reader showing it.
///
/// Unlike `ReaderPassageTarget` this is a standing request: the reader scrolls
/// to the target and keeps it outlined for as long as the step is current, and
/// the next step or the chat's close replaces or clears it. The figure's
/// geometry is carried along when the figure index knows it; when it does not,
/// the reader finds the figure from its caption on the page itself.
struct ReaderWalkthroughFocus: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A figure on a page: the analysed rectangle when there is one (a
        /// panel's, when the step names a panel the analysis knows), else the
        /// caption the reader crops around.
        case figure(pageIndex: Int, rect: PaperFigureRect?, caption: String, sharesPageWithOtherFigures: Bool)
        /// A run of the paper's words, found on the page as a citation is.
        case passage(String, pageHint: Int?)
        /// A page and nothing more specific.
        case page(pageIndex: Int)
    }

    /// How the target is shown. A walkthrough outlines it; a lesson
    /// (docs/lesson-design.md) dims the rest of its page around it, and a
    /// prediction covers the figure's data until the learner has guessed.
    enum Emphasis: Equatable, Sendable {
        case outline
        case spotlight
        case veiled
    }

    /// One panel a lesson's Find it lets the learner click on the page: its
    /// letter and its rectangle on the figure's page.
    struct PickablePanel: Equatable, Sendable {
        let label: String
        let rect: PaperFigureRect
    }

    let sourceID: String
    let stepID: String
    let target: Target
    let revision: UInt
    var emphasis: Emphasis = .outline
    /// A Find it's panels, each a click target on the page; empty otherwise.
    var pickablePanels: [PickablePanel] = []
    /// The Studio window of the chat pointing (`ReaderRequestWindow`); nil
    /// reaches a Reader in any window.
    var windowID: UUID? = nil
}

/// Walk Through was pressed on a source: the chat beside the Reader plays
/// its walkthrough. The revision makes two presses two requests.
struct ReaderWalkthroughPlayRequest: Equatable, Sendable {
    /// The subject's id: a source, or a saved animation's artifact id.
    let sourceID: String
    let revision: UInt
    /// True when the subject is an animation shown in the Animations pane
    /// rather than a source read in the Reader.
    var isAnimation: Bool = false
}

/// Where a walkthrough step that shows a saved animation points every pane
/// showing that animation: its page pinned to `step` under `conditions`,
/// through the page's walk API (`window.ForeverLMWalk.show`). The revision
/// makes the same step asked for twice two requests.
struct AnimationWalkFocus: Equatable, Sendable {
    let artifactID: String
    let step: Int
    let conditions: [String: String]
    let revision: UInt

    /// The call the page answers.
    var script: String {
        let conditionsJSON = (try? JSONSerialization.data(withJSONObject: conditions, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "(function(){ if (window.ForeverLMWalk) { window.ForeverLMWalk.show(\(step), \(conditionsJSON)); return true; } return false; })()"
    }
}

/// What the chat asks the Reader to do for a walkthrough step it plays, or
/// for the tutor's `focus_source_anchor` call: keep a figure, panel, passage
/// or page outlined on a PDF; scroll to and flash a passage of a source shown
/// as text; or take the outline down. `StudioViewModel.applyWalkthroughReaderFocus`.
enum WalkthroughReaderFocus: Equatable, Sendable {
    case outline(ReaderWalkthroughFocus.Target, stepID: String, sourceID: String)
    /// A lesson's turn: the target outlined with the rest of its page dimmed,
    /// and — for a prediction still waiting for its guess — its data covered.
    case spotlight(ReaderWalkthroughFocus.Target, stepID: String, sourceID: String, veiled: Bool)
    /// A lesson's Find it: the figure spotlit, each of `panels` a click target
    /// the Reader hands back through `readerPanelPickHandler`.
    case pickPanel(ReaderWalkthroughFocus.Target, stepID: String, sourceID: String, panels: [ReaderWalkthroughFocus.PickablePanel])
    case flash(passage: String, sourceID: String)
    /// A video's walk: seek the Reader's player to the step's moment, paused,
    /// so the card is read with the talk's slide on screen.
    case moment(seconds: Int, sourceID: String)
    /// Point every pane showing the saved animation at one of its steps.
    case animation(artifactID: String, step: Int, conditions: [String: String])
    case clear
}

/// The `t=` query of an in-app source link, in the forms a model writes when it
/// reads the time off a `[12:34]` transcript marker: plain seconds (`754`,
/// `754s`), `12m34s` / `1h2m3s`, or the marker itself (`12:34`, `1:02:03`).
/// Anything else is no moment rather than a guess. Mirrors `secondsFromTimeAnchor`
/// in the chat renderer, so a marker and the app agree on what a link means.
enum SourceLinkTimeAnchor {
    static let queryItemName = "t"

    static func seconds(from value: String?) -> Double? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        let seconds: Double?
        if text.range(of: #"^\d+(\.\d+)?s?$"#, options: .regularExpression) != nil {
            seconds = Double(text.hasSuffix("s") ? String(text.dropLast()) : text)
        } else if text.range(of: #"^(\d+:)?\d{1,2}:\d{2}(\.\d+)?$"#, options: .regularExpression) != nil {
            let parts = text.split(separator: ":").map { Double($0) ?? .nan }
            seconds = parts.reduce(0) { $0 * 60 + $1 }
        } else if text.range(of: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$"#, options: .regularExpression) != nil {
            var total = 0.0
            var number = ""
            for character in text {
                if character.isNumber || character == "." {
                    number.append(character)
                } else {
                    let value = Double(number) ?? .nan
                    number = ""
                    switch character {
                    case "h": total += value * 3600
                    case "m": total += value * 60
                    case "s": total += value
                    default: return nil
                    }
                }
            }
            seconds = total
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    /// The moment carried by an in-app source URL, or nil when it names none.
    static func seconds(in url: URL) -> Double? {
        seconds(from: URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == queryItemName })?
            .value)
    }
}

/// The `q=` query of an in-app source link: the passage a citation of a text
/// source points at, for links built outside the chat renderer — a deep link,
/// or a tool that writes the query rather than a markdown title. Empty is no
/// passage.
enum SourceLinkPassageAnchor {
    static let queryItemName = "q"

    static func passage(in url: URL) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == queryItemName })?
            .value?
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// The `page=` query of an in-app source link: the page of a PDF source a
/// citation points at, one-based and counted within that source's own pages
/// (a book chapter's, not the book's), the way the `[page N]` markers in the
/// text the model reads count them. Anything but a positive whole number is
/// no page rather than a guess.
enum SourceLinkPageAnchor {
    static let queryItemName = "page"

    static func page(from value: String?) -> Int? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil,
              let page = Int(text), page >= 1 else { return nil }
        return page
    }

    /// The page carried by an in-app source URL, or nil when it names none.
    static func page(in url: URL) -> Int? {
        page(from: URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == queryItemName })?
            .value)
    }
}

enum PodcastSpeakerNameInference {
    struct Turn: Equatable {
        let speakerID: String
        let text: String
    }

    static func speakerIDs(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\bSPEAKER_(\d+)\b|\bSpeaker\s+(\d+)\b"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            if match.range(at: 1).location != NSNotFound,
               let idRange = Range(match.range(at: 1), in: text) {
                return "SPEAKER_\(text[idRange])"
            }
            if match.range(at: 2).location != NSNotFound,
               let numberRange = Range(match.range(at: 2), in: text) {
                return "SPEAKER_\(text[numberRange])"
            }
            return nil
        })
    }

    static func evidenceSummary(from raw: String, speakerIDs: Set<String>, maxCharacters: Int = 14_000) -> String {
        let turns = speakerTurns(in: raw)
        guard !turns.isEmpty else { return "No structured speaker turns found." }

        var lines: [String] = []
        lines.append("Early chronological turns:")
        for (offset, turn) in turns.prefix(12).enumerated() {
            lines.append("\(offset + 1). \(turn.speakerID): \(shortExcerpt(turn.text, maxLength: 360))")
        }

        lines.append("Representative turns by speaker (early, middle, and late):")
        for speakerID in speakerIDs.sorted() {
            let matching = turns.enumerated().filter { $0.element.speakerID == speakerID }
            guard !matching.isEmpty else { continue }
            let positions = Set([0, matching.count / 2, matching.count - 1]).sorted()
            for position in positions {
                let item = matching[position]
                lines.append("turn \(item.offset + 1), \(speakerID): \(shortExcerpt(item.element.text, maxLength: 520))")
            }
        }

        if turns.count > 12 {
            lines.append("Final chronological turns:")
            for item in turns.enumerated().suffix(6) {
                lines.append("turn \(item.offset + 1), \(item.element.speakerID): \(shortExcerpt(item.element.text, maxLength: 360))")
            }
        }

        let missingIDs = speakerIDs.subtracting(Set(turns.map(\.speakerID)))
        if !missingIDs.isEmpty {
            lines.append("Speaker IDs without parsed turns: \(missingIDs.sorted().joined(separator: ", "))")
        }

        var summary = lines.joined(separator: "\n")
        if summary.count > maxCharacters {
            summary = String(summary.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return summary
    }

    static func isValidPersonName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let roleLabels: Set<String> = [
            "host", "cohost", "co host", "guest", "interviewer", "interviewee",
            "narrator", "producer", "speaker", "transcript", "unknown"
        ]
        if roleLabels.contains(normalized) { return false }
        if normalized.range(of: #"^speaker\s*\d+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Recover persisted speaker-name overrides for the raw TTML reader. The raw
    /// transcript carries stable speaker IDs and timestamps, while the editable
    /// transcript carries the AI/manual names. Aligning their unchanged words
    /// keeps the raw reader rich without treating a name as record identity.
    static func displayNameOverrides(
        rawSegments: [PodcastTranscriptSegment],
        storedSegments: [PodcastTranscriptSegment]
    ) -> [String: String] {
        guard !rawSegments.isEmpty, !storedSegments.isEmpty else { return [:] }

        var storedIndex = 0
        var candidates: [String: Set<String>] = [:]

        for rawSegment in rawSegments {
            let rawText = normalizedTurnText(rawSegment.text)
            guard !rawText.isEmpty else { continue }

            var combinedText = ""
            var labels: [String] = []
            var matched = false

            while storedIndex < storedSegments.count {
                let storedSegment = storedSegments[storedIndex]
                storedIndex += 1
                let nextText = normalizedTurnText(storedSegment.text)
                combinedText = combinedText.isEmpty ? nextText : combinedText + " " + nextText
                labels.append(storedSegment.speakerLabel)

                if combinedText == rawText {
                    matched = true
                    break
                }
                if !rawText.hasPrefix(combinedText) || combinedText.count >= rawText.count {
                    return [:]
                }
            }

            guard matched else { return [:] }
            for label in labels where isValidPersonName(label) {
                candidates[rawSegment.speakerID, default: []].insert(label)
            }
        }

        guard storedIndex == storedSegments.count else { return [:] }
        return candidates.compactMapValues { names in
            names.count == 1 ? names.first : nil
        }
    }

    private static func speakerTurns(in raw: String) -> [Turn] {
        let bracketPattern = #"(?ms)(?:^|\n)\s*\[(SPEAKER_\d+|Speaker\s+\d+)\]\s*\n(.*?)(?=\n\s*\[(?:SPEAKER_\d+|Speaker\s+\d+)\]\s*\n|\z)"#
        let boldPattern = #"(?ms)(?:^|\n)\s*\*\*(SPEAKER_\d+|Speaker\s+\d+):\*\*\s*(.*?)(?=\n\s*\*\*(?:SPEAKER_\d+|Speaker\s+\d+):\*\*|\z)"#
        let bracketTurns = turns(matching: bracketPattern, in: raw)
        if !bracketTurns.isEmpty { return bracketTurns }
        return turns(matching: boldPattern, in: raw)
    }

    private static func turns(matching pattern: String, in raw: String) -> [Turn] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.matches(in: raw, range: range).compactMap { match in
            guard let speakerRange = Range(match.range(at: 1), in: raw),
                  let textRange = Range(match.range(at: 2), in: raw) else { return nil }
            let speakerID = normalizedSpeakerID(String(raw[speakerRange]))
            let text = String(raw[textRange])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Turn(speakerID: speakerID, text: text)
        }
    }

    private static func normalizedSpeakerID(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return upper.replacingOccurrences(of: " ", with: "_")
    }

    private static func shortExcerpt(_ text: String, maxLength: Int) -> String {
        var excerpt = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if excerpt.count > maxLength {
            excerpt = String(excerpt.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return excerpt
    }

    private static func normalizedTurnText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PodcastSortMode: String, CaseIterable, Codable {
    case date
    case channel

    var title: String {
        switch self {
        case .date: return "Date"
        case .channel: return "Podcast Channel"
        }
    }

    /// Compact label for the segmented sort control in the filter popover.
    var shortTitle: String {
        switch self {
        case .date: return "Date"
        case .channel: return "Channel"
        }
    }

    var icon: String {
        switch self {
        case .date: return "calendar"
        case .channel: return "rectangle.stack"
        }
    }
}

enum VideoSortMode: String, CaseIterable, Codable {
    /// Liked-feed order: the YouTube `LL` position captured at ingest, which is
    /// most-recently-liked first. The historical (and still default) order.
    case liked
    /// The video's own publication date, newest first — independent of when it
    /// was liked or imported.
    case published

    var title: String {
        switch self {
        case .liked: return "Date Liked"
        case .published: return "Date Published"
        }
    }

    /// Compact label for the segmented sort control in the filter popover.
    var shortTitle: String {
        switch self {
        case .liked: return "Liked"
        case .published: return "Published"
        }
    }

    var icon: String {
        switch self {
        case .liked: return "hand.thumbsup"
        case .published: return "calendar"
        }
    }
}

/// How the Meetings tab lays its sessions out.
enum MeetingListOrder: String, CaseIterable, Codable {
    /// One row per series, each opening onto its own sessions. The default.
    case bySeries
    /// Every session on its own row, newest first, whichever series it belongs to.
    case byDate

    var title: String {
        switch self {
        case .bySeries: return "By Series"
        case .byDate: return "By Date"
        }
    }
}

enum ApplePodcastDiscoveryScope: String, CaseIterable, Identifiable {
    case listened
    case downloadedOrListened
    case completed

    static let defaultsKey = Prefs.Discovery.applePodcastDiscoveryScope.name

    var id: String { rawValue }

    static var current: ApplePodcastDiscoveryScope {
        get {
            guard let raw = Preferences.value(Prefs.Discovery.applePodcastDiscoveryScope),
                  let scope = ApplePodcastDiscoveryScope(rawValue: raw) else {
                return .listened
            }
            return scope
        }
        set {
            Preferences.set(newValue.rawValue, for: Prefs.Discovery.applePodcastDiscoveryScope)
        }
    }

    var title: String {
        switch self {
        case .listened: return "Partially listened"
        case .downloadedOrListened: return "Downloaded or listened"
        case .completed: return "Finished"
        }
    }

    var description: String {
        switch self {
        case .listened:
            return "Import recent episodes after Apple records playback progress or a played timestamp."
        case .downloadedOrListened:
            return "Also include episodes Apple has downloaded locally."
        case .completed:
            return "Only import recent episodes Apple marks as completed."
        }
    }
}

/// What's New on a reader mark: research what has been published since the
/// source was written, in a Deep Research chat, and write the short version
/// back onto the mark (chat-design.md, "What's New").
struct ReaderResearchUpdate: Equatable {
    /// The mark the research is about. The chat links itself to it on its
    /// first send (`ReviewSessionManager.pendingSourceHighlightLink`).
    let highlightID: String
    /// What the source is, for the research: its title and, for a book
    /// chapter, the book, edition and author the library knows. The year a
    /// source was written decides what counts as new.
    let sourceDescription: String
}

/// **Find directions** on a Goal, Notebook or Idea (docs/directions-design.md):
/// a Deep Research chat that is sent at once, whose first message asks for
/// directions toward the home and whose model-only context tells it to start
/// from `find_directions`.
struct DirectionSearchLaunch: Equatable {
    let homeKind: DirectionHomeKind
    let homeID: String
    let homeTitle: String
    /// The Notebook the chat is filed beside: the home itself when it is a
    /// Notebook, the Notebook a Goal is tagged to, nil for an Idea or an
    /// untagged Goal.
    let notebookID: String?
    /// What the learner would try, written before the search (Think first):
    /// one candidate the search weighs with the rest. Nil when not asked or
    /// skipped.
    var learnerCandidate: String? = nil

    /// What the learner is shown having sent.
    var message: String { "Find directions for “\(homeTitle)”" }
}

/// Think first's ask before **Find directions** (docs/fences-and-think-first-design.md):
/// the search it is holding, and where the learner's answer goes.
struct DirectionTakeRequest: Identifiable, Equatable {
    let id = UUID()
    let launch: DirectionSearchLaunch
    let sourceIDs: [String]
}

struct ReaderSelectionExplanationRequest: Identifiable, Equatable {
    let id = UUID()
    let sourceIDs: [String]
    let selectedText: String
    let contextTitle: String?
    /// Lean provenance for Article-originated prompts. The chat persists the
    /// exact passage/excerpt it used plus this stable pointer; it never clones
    /// the complete Article into each conversation.
    let artifactID: String?
    let artifactRevision: String?
    let artifactNotebookID: String?
    let selectionRange: Range<Int>?
    let contextExcerpt: String?
    /// The doc itself, attached the way a dropped Doc is — title, revision and
    /// outline, never the body — so the chat can read past the excerpt with
    /// `read_doc` when the question turns out to need the whole document.
    let artifactAttachment: ChatDocAttachment?
    /// The heading the passage sat under, kept raw so a stored link can say
    /// where in a long doc the conversation started. `contextTitle` already
    /// carries the same words glued to the doc's name for the model to read;
    /// that string is prose, not a field.
    let sectionTitle: String
    /// An exchange lifted out of a memory review, when that is what this request
    /// carries instead of a passage. The chip still shows `selectedText` (the
    /// tutor's question); the model reads the exchange, the ideas the grader
    /// missed, and the framing that says this chat is not the review.
    let reviewHandoff: MemoryReviewChatHandoff?
    /// A side question lifted out of a quiz, when that is what this request
    /// carries. The chip shows `selectedText` (the side question's first line);
    /// the model reads the aside, its replies, and the framing that says this
    /// chat is not the quiz.
    let sideQuestionHandoff: ChatSideQuestionHandoff?
    /// The pictures the Reader selection covered, already fetched and prepared,
    /// to go into the composer's tray beside the passage. A selection over a
    /// figure alone has an empty `selectedText` and one of these.
    let imageAttachments: [ChatImageAttachment]
    /// What's New on a saved mark, when that is what this request carries:
    /// the passage is researched in a Deep Research chat that is sent at once
    /// rather than staged, and the chat links itself to the mark.
    let researchUpdate: ReaderResearchUpdate?
    /// Find directions, when that is what this request carries: like What's
    /// New, a Deep Research chat sent at once rather than staged, about a
    /// Goal, Notebook or Idea instead of a passage.
    let directionSearch: DirectionSearchLaunch?

    /// Research sent in the learner's name the moment the chat can take it —
    /// What's New or Find directions — rather than a passage left under the
    /// composer.
    var sendsAtOnce: Bool { researchUpdate != nil || directionSearch != nil }

    /// The durable half of this request: what a stored link needs to point back
    /// at the passage after the pane has forgotten it. nil for a reader
    /// selection, which is a source and not a doc.
    var docAnchor: ChatDocAnchor? {
        guard let artifactID, !artifactID.isEmpty else { return nil }
        let quote = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        return ChatDocAnchor(
            artifactID: artifactID,
            artifactRevision: artifactRevision ?? "",
            selectionStart: selectionRange?.lowerBound ?? 0,
            selectionEnd: selectionRange?.upperBound ?? 0,
            quote: quote,
            sectionTitle: sectionTitle
        )
    }

    /// A passage out of a source: the Reader's Chat pill, ⇧⌘K, a highlight's
    /// note. Only this kind is judged against the open chat's sources before
    /// it is staged; a doc's passage, a review's exchange and a quiz's side
    /// question each name their own grounding and have already asked for a
    /// fresh chat by the time they arrive (a doc's passage has it only when the
    /// chat on screen is not already working on that doc).
    var isReaderSelection: Bool {
        artifactID == nil && reviewHandoff == nil && sideQuestionHandoff == nil && directionSearch == nil
    }

    init(
        sourceID: String,
        selectedText: String,
        imageAttachments: [ChatImageAttachment] = [],
        researchUpdate: ReaderResearchUpdate? = nil
    ) {
        sourceIDs = [sourceID]
        self.selectedText = selectedText
        contextTitle = nil
        artifactID = nil
        artifactRevision = nil
        artifactNotebookID = nil
        selectionRange = nil
        contextExcerpt = nil
        artifactAttachment = nil
        sectionTitle = ""
        reviewHandoff = nil
        sideQuestionHandoff = nil
        self.imageAttachments = imageAttachments
        self.researchUpdate = researchUpdate
        directionSearch = nil
    }

    /// Find directions on a home: the chat starts with the home's sources in
    /// context and the request to search.
    init(directionSearch: DirectionSearchLaunch, sourceIDs: [String]) {
        self.sourceIDs = sourceIDs
        selectedText = directionSearch.message
        contextTitle = nil
        artifactID = nil
        artifactRevision = nil
        artifactNotebookID = nil
        selectionRange = nil
        contextExcerpt = nil
        artifactAttachment = nil
        sectionTitle = ""
        reviewHandoff = nil
        sideQuestionHandoff = nil
        imageAttachments = []
        researchUpdate = nil
        self.directionSearch = directionSearch
    }

    init(
        sourceIDs: [String],
        selectedText: String,
        contextTitle: String?,
        artifactID: String? = nil,
        artifactRevision: String? = nil,
        artifactNotebookID: String? = nil,
        selectionRange: Range<Int>? = nil,
        contextExcerpt: String? = nil,
        artifactAttachment: ChatDocAttachment? = nil,
        sectionTitle: String = "",
        reviewHandoff: MemoryReviewChatHandoff? = nil,
        sideQuestionHandoff: ChatSideQuestionHandoff? = nil,
        imageAttachments: [ChatImageAttachment] = []
    ) {
        self.sourceIDs = sourceIDs
        self.selectedText = selectedText
        self.contextTitle = contextTitle
        self.artifactID = artifactID
        self.artifactRevision = artifactRevision
        self.artifactNotebookID = artifactNotebookID
        self.selectionRange = selectionRange
        self.contextExcerpt = contextExcerpt
        self.artifactAttachment = artifactAttachment
        self.sectionTitle = sectionTitle
        self.reviewHandoff = reviewHandoff
        self.sideQuestionHandoff = sideQuestionHandoff
        self.imageAttachments = imageAttachments
        researchUpdate = nil
        directionSearch = nil
    }

    /// The message a What's New request sends in the learner's name: short,
    /// because the passage shows above it and the steps ride in the context.
    static let researchUpdateMessage = "What's new since this was written?"

    /// A Reader selection of pictures and no words.
    var isPictureOnly: Bool {
        !imageAttachments.isEmpty && !SourceHighlight.hasWords(selectedText)
    }

    func contextualContent(fallbackTitle: String? = nil) -> String {
        // A review exchange is not a passage: the exchange itself is the
        // context, and it comes with its own framing.
        if let reviewHandoff { return reviewHandoff.contextualContent }
        // Nor is a side question: the aside and its replies are the context.
        if let sideQuestionHandoff { return sideQuestionHandoff.contextualContent }
        // Nor is a direction search: the home is named, and the brief is the
        // chat's first tool call.
        if let directionSearch {
            return Prompts.directionSearchRequest(
                homeKind: directionSearch.homeKind,
                homeID: directionSearch.homeID,
                learnerCandidate: directionSearch.learnerCandidate
            )
        }

        let passage = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty || !imageAttachments.isEmpty else { return "" }

        let preferredTitle = contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (preferredTitle?.isEmpty == false ? preferredTitle : fallback) ?? ""
        var head: [String] = []
        if !passage.isEmpty {
            let quotedPassage = passage
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            head.append("Selected passage:\n\(quotedPassage)")
        }
        // The pictures ride in the message itself as image parts; this line
        // tells the model which of them the selection was, by the names the
        // image lines carry. Under the passage's heading, so
        // `ChatPassageOrigin` still reads the words first.
        if !imageAttachments.isEmpty {
            head.append(Self.selectedPicturesLine(names: imageAttachments.map(\.name)))
        }
        if !label.isEmpty { head.append("Context: \(label)") }
        var blocks = [head.joined(separator: "\n\n")]

        if let excerpt = contextExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty,
           excerpt != passage {
            blocks.append("Exact surrounding excerpt:\n<article_excerpt>\n\(excerpt)\n</article_excerpt>")
        }
        if let artifactID, !artifactID.isEmpty {
            var reference = "Article ID: \(artifactID)"
            if let artifactRevision, !artifactRevision.isEmpty {
                reference += "\nArticle revision: \(artifactRevision)"
            }
            if let artifactNotebookID, !artifactNotebookID.isEmpty {
                reference += "\nNotebook ID: \(artifactNotebookID)"
            }
            if let selectionRange {
                reference += "\nSelection range: \(selectionRange.lowerBound)..<\(selectionRange.upperBound)"
            }
            blocks.append(reference)
        } else if isReaderSelection, let sourceLine = ChatPassageOrigin.sourceIDLine(for: sourceIDs) {
            // The Reader's passage names its source the way a doc's names its
            // doc, so the chat can open the source at these words later
            // (`ChatPassageOrigin`).
            blocks.append(sourceLine)
        }
        // What's New: the research steps follow the passage, in their own
        // block, so `ChatPassageOrigin` still reads the passage first.
        if let researchUpdate {
            blocks.append(Prompts.readerPassageUpdate(
                highlightID: researchUpdate.highlightID,
                sourceDescription: researchUpdate.sourceDescription
            ))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// "Selected picture: attached to this message as "Figure 2"." — or the
    /// plural, with every name.
    static func selectedPicturesLine(names: [String]) -> String {
        let quoted = names.map { "\"\($0)\"" }
        if quoted.count == 1 {
            return "Selected picture: attached to this message as \(quoted[0])."
        }
        return "Selected pictures: \(quoted.count), attached to this message as \(quoted.joined(separator: ", "))."
    }
}

extension ReaderSelectionExplanationRequest {
    /// A side question handed to a new chat, as the request the chat pane
    /// already knows how to stage: the aside's first line is the chip's line,
    /// the exchange and the framing are the model-only context, and the quiz's
    /// sources become the chat's.
    init(sideQuestionHandoff handoff: ChatSideQuestionHandoff) {
        self.init(
            sourceIDs: handoff.sourceIDs,
            selectedText: handoff.headline,
            contextTitle: handoff.origin == .reader
                ? "Side chat on: \(handoff.chatTitle)"
                : "Side question from: \(handoff.chatTitle)",
            sideQuestionHandoff: handoff
        )
    }
}

/// Where in a doc a conversation started, carried from the editor to the chat so
/// the chat can write it down once it has a session to write it against.
///
/// A chat is opened before it exists: the passage is chosen, then the question is
/// typed, and only sending it creates the session the link needs a foreign key
/// to. This value is what survives that gap.
struct ChatDocAnchor: Equatable, Sendable {
    let artifactID: String
    /// The doc's body revision when the passage was highlighted. The offsets
    /// below describe that revision and no other; an empty string means the doc
    /// had no packaged body yet, so only the quote can be trusted.
    let artifactRevision: String
    let selectionStart: Int
    let selectionEnd: Int
    let quote: String
    let sectionTitle: String
}

/// A doc the Notepad canvas should bring forward and select — the way back from
/// a chat to the passage that started it. The token makes a repeat request for
/// the same doc a distinct value, so the canvas acts on it again.
struct ArtifactRevealRequest: Equatable {
    let artifactID: String
    /// Which canvas answers: the Docs canvases or the Sites one. Both observe
    /// the request, and only the section that lists the record consumes it.
    var section: ArtifactSection = .docs
    /// The Studio window the request was made for (`StudioWindowState.id`).
    /// Every window's canvas observes the one request, so without this a doc
    /// revealed in one window would come forward in every window.
    let windowID: UUID
    /// The block to show once the doc is open — a block reference or a
    /// linked reference followed (`openDoc(_:revealing:in:)`); nil opens the
    /// doc where it opens.
    var block: DocBlockReveal? = nil
    /// The pane whose canvas answers, when the place stands in more than one
    /// pane of the window (`StudioCenterTab.copyablePlaces`); nil lets any
    /// canvas of the window and section answer.
    var groupID: UUID? = nil
    let token = UUID()
}

/// A request that the Browser pane open a page in a new tab. The token makes
/// two requests for the same address distinct, so a second click opens a
/// second tab rather than being read as the first.
struct BrowserOpenRequest: Equatable {
    let url: URL
    /// The profile the tab opens in; nil is the Library profile.
    var profileID: UUID? = nil
    let token = UUID()
}

/// A request that a section's canvas show the index of every entry rather
/// than whichever one it last had open. The rail's Docs and Sites rows each
/// make one on every click; the token keeps a second click from reading as
/// the first, and the section keeps the other canvas from answering.
struct ArtifactIndexRequest: Equatable {
    var section: ArtifactSection = .docs
    /// The Studio window whose canvas shows the index. The product owner (2026-09-12),
    /// with a doc open on one display: clicking Docs in the window on the other
    /// display sent this window back to the Docs home too — "the left display
    /// window shouldn't change at all". The canvas of any other window leaves
    /// the request alone.
    let windowID: UUID
    /// The pane whose canvas shows the index, as for `ArtifactRevealRequest`.
    var groupID: UUID? = nil
    let token = UUID()
}

/// What a chat pane's doc-link lookup depends on: which conversation is showing,
/// and whether anything has written a link since. Both have to key one `.task`,
/// because a link can appear without the session changing — the pane's own send
/// writes one into the conversation already on screen.
struct ChatDocLinkKey: Equatable {
    let sessionID: String?
    let revision: UUID
}

/// A doc passage and the conversation it started, resolved together so a row can
/// show both the words that were asked about and what the chat was called.
struct ArtifactChatLink: Identifiable, Equatable {
    let link: ArtifactChatLinkRecord
    let session: ReviewSessionRecord

    var id: String { link.id }

    /// What to call this conversation in a list. A chat whose title never got
    /// past its provisional state would otherwise draw a blank row.
    var displayTitle: String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled chat" : title
    }
}

/// The words a chat's header and a side chat's pill show for a chat that has a
/// row: the saved title, then the topic. While the title is only the opening
/// message echoed back (the AI-suggested title is pending), the first bubble
/// would be said twice, so the line says "New chat" until a title exists; a
/// manual rename differs from the echoed topic and wins.
enum ChatHeaderTitle {
    static func title(sessionTitle: String?, topic: String, isProvisional: Bool) -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (saved?.isEmpty == false ? saved : nil) ?? trimmedTopic
        if isProvisional, title == trimmedTopic { return "New chat" }
        return title.isEmpty ? "Untitled chat" : title
    }
}

/// The page a side chat floats over, as the chat needs to know it
/// (docs/pages-side-chat-design.md).
struct PageSideChatPage: Equatable {
    let artifactID: String
    var title: String
    /// The stored revision, not the unsaved draft: the text `read_doc` returns.
    var revision: String
    /// The Notebook the page lives in, which frames the chat as it frames a
    /// chat opened from the Notebook itself.
    var notebookID: String?
    /// The page by identity — title, revision, outline, never the body — so the
    /// chat can read all of it with `read_doc`. Nil until the page has loaded.
    var attachment: ChatDocAttachment?

    /// What the first send of a chat about the whole page writes into
    /// `artifact_chat_links`, as a passage's chat writes its passage. The table
    /// and `link_doc_passage_to_chat` need words, so the quote is the page's
    /// name, at offsets 0..0; the page's Discussion and `list_doc_chats` then
    /// list the chat like any other the page started.
    var wholePageAnchor: ChatDocAnchor {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatDocAnchor(
            artifactID: artifactID,
            artifactRevision: revision,
            selectionStart: 0,
            selectionEnd: 0,
            quote: name.isEmpty ? "Untitled page" : name,
            sectionTitle: ""
        )
    }
}

/// What the page asks its side chat to open: everything
/// `StudioViewModel.requestNotepadChat` set on the view model for the docked
/// route, as one value for the card's own store.
struct PageSideChatOpening: Identifiable, Equatable {
    let id = UUID()
    let page: PageSideChatPage
    /// The sources the chat stands on: the ones the highlighted passage cites,
    /// else the page's own shelf and its Notebooks'.
    let sourceIDs: [String]
    /// The highlighted passage with its revision pointer, staged under the
    /// composer; nil when the chat is about the page as a whole.
    let passage: ReaderSelectionExplanationRequest?
    /// A Prompt block's words, waiting under the composer to be edited and
    /// sent by the writer.
    let draft: String?
    /// Add to Chat, which adds the page to a conversation rather than
    /// starting one: when the card already holds a conversation about this
    /// page it is brought forward and nothing is reset.
    var joinsOpenChat = false
}

/// What the page's menu and the card ask the editor for, because only the
/// editor holds the page's text and its sources.
struct PageSideChatWholePageRequest: Identifiable, Equatable {
    enum Intent: Equatable {
        /// The page menu's Add to Chat.
        case addToChat
        /// The card's New chat.
        case newChat
    }

    let id = UUID()
    let intent: Intent
}

/// Which chats list under a page in its side chat's ⌄ menu.
enum PageSideChatChats {
    /// What a chat is called in the menu: its saved title, or "Untitled chat"
    /// for one whose title never got past its provisional state.
    static func title(of session: ReviewSessionRecord) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled chat" : title
    }

    /// The page's saved chats, once each, newest link first. A chat can hold
    /// several passages of one page; it is one row. A hidden chat is not
    /// offered, and neither is a transcript a team shared (read-only).
    static func sessions(from links: [ArtifactChatLink]) -> [ReviewSessionRecord] {
        var seen = Set<String>()
        var sessions: [ReviewSessionRecord] = []
        let newestFirst = links.sorted {
            if $0.link.createdAt != $1.link.createdAt { return $0.link.createdAt > $1.link.createdAt }
            return $0.link.id < $1.link.id
        }
        for entry in newestFirst {
            guard entry.session.hiddenAt == nil, entry.session.teamID == nil,
                  seen.insert(entry.session.id).inserted else { continue }
            sessions.append(entry.session)
        }
        return sessions
    }
}

/// The card's measurements. The width is the reply side chat's, at the chat's
/// zoom (`ReviewChatSideChatPopover.width(zoom:)`).
enum PageSideChatLayout {
    /// Room the card keeps from the pane's trailing and bottom edges.
    static let edgeInset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    /// The most of the pane's height the card takes once a conversation shows.
    static let paneHeightShare: CGFloat = 0.6
    /// What the header and the composer take at zoom one, which the
    /// transcript's share is counted without.
    static let chromeAllowance: CGFloat = 150
    static let minimumTranscriptHeight: CGFloat = 160

    /// The card's width: the wanted one, unless the pane cannot hold it with
    /// its margins on both sides.
    static func width(wanted: CGFloat, paneWidth: CGFloat) -> CGFloat {
        guard paneWidth > 0 else { return wanted }
        return min(wanted, max(0, paneWidth - 2 * edgeInset))
    }

    /// The scrolling transcript's height. The transcript is a web view that
    /// cannot report its content height, so the region is one height whatever
    /// the conversation: the card as a whole, header and composer included,
    /// stays within `paneHeightShare` of the pane where the pane allows.
    static func transcriptHeight(paneHeight: CGFloat, zoom: CGFloat) -> CGFloat {
        let floor = (minimumTranscriptHeight * zoom).rounded()
        guard paneHeight > 0 else { return floor }
        return max(floor, (paneHeight * paneHeightShare - chromeAllowance * zoom).rounded())
    }
}

/// The live text selection in whichever reader is frontmost, so ⇧⌘K can chat about
/// it instead of just toggling the assistant. Kept deliberately tiny.
struct ReaderChatSelection: Equatable {
    let sourceID: String
    let text: String
    /// The pictures the selection covers, for a web reader; empty elsewhere.
    var images: [ReaderSelectionImage] = []
}

/// A source the sidebar should scroll into view, so a jump from elsewhere in the
/// app (following a chat citation) lands on a row the user can actually see.
/// Selecting the source only highlights its row; without this the row can sit far
/// below the fold. The token makes a repeat reveal of the same source a distinct
/// request, so the sidebar re-runs the scroll instead of ignoring an equal value.
struct SidebarRevealRequest: Equatable {
    let sourceID: String
    let token = UUID()
}

enum StudioYouTubeMetadataApplicator {
    static func apply(_ metadata: YouTubeTranscriptService.VideoMetadata, to article: inout StudioArticle) {
        article.title = metadata.title
        if let channelName = metadata.channelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !channelName.isEmpty {
            article.domain = channelName
        }
        if let thumbnailURL = metadata.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thumbnailURL.isEmpty {
            article.artworkURL = thumbnailURL
        } else if article.artworkURL == nil {
            article.artworkURL = article.youtubeThumbnailURL
        }
    }
}

/// The passage highlighted on a Page right now. A chat beside that Page shows
/// it as the quote its next message carries, so what the writer highlights is
/// what the chat is asked about (product owner, 2026-11-10: "stuff i highlight
/// on a page should also be visible here in the chat").
struct LivePageSelection: Equatable, Sendable {
    let artifactID: String
    let text: String
}

/// How a chat's quoted passage follows the Page highlighted beside it.
///
/// The chat owns at most one mirrored quote: a new highlight replaces it, and
/// an emptied highlight takes it away. A quote the learner put there
/// themselves (Quote in Reply, a recalled message) is theirs, and a highlight
/// never overwrites or removes it.
enum PageSelectionQuote {
    struct State: Equatable {
        var quote: String
        /// The quote as the mirror last set it; nil when the mirror set none.
        var mirrored: String?
    }

    /// - Parameter highlight: the highlighted text on a Page beside this chat,
    ///   or nil when nothing is highlighted there.
    static func next(_ state: State, highlight: String?) -> State {
        let text = highlight?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mirrorOwnsQuote = state.quote.isEmpty || state.quote == state.mirrored
        guard mirrorOwnsQuote else {
            // The learner's own quote stands; forget any stale mirror.
            return State(quote: state.quote, mirrored: nil)
        }
        if text.isEmpty {
            return State(quote: "", mirrored: nil)
        }
        return State(quote: text, mirrored: text)
    }
}
