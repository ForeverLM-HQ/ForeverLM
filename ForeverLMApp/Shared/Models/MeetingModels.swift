// Meeting models, moved out of Models.swift.

import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Meetings

/// When a meeting series meets: the weekdays, the start on the clock, how
/// long, and the time zone the clock is read in. Structure, not prose —
/// `recurrenceRule` stays the human line under the folder's name; this is
/// what the Planner draws from (planner-design.md, "A meeting series on the
/// clock"). Weekdays follow `Calendar`: 1 is Sunday, 7 is Saturday.
struct MeetingSchedule: Codable, Equatable, Hashable, Sendable {
    var weekdays: [Int]
    var startMinute: Int
    var durationMinutes: Int
    var timezone: String

    static let weekdayRange = 1...7
    static let workdays = [2, 3, 4, 5, 6]

    init(weekdays: [Int], startMinute: Int, durationMinutes: Int, timezone: String) {
        self.weekdays = Array(Set(weekdays.filter { Self.weekdayRange.contains($0) })).sorted()
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timezone = timezone
    }

    /// A schedule the Planner can draw: at least one weekday, a start on the
    /// clock, a duration of at least the smallest block, and a zone `TimeZone`
    /// knows. A synced record from a client that wrote something else is
    /// held but never drawn.
    var isValid: Bool {
        !weekdays.isEmpty
            && (0..<(24 * 60)).contains(startMinute)
            && durationMinutes >= 5
            && startMinute + durationMinutes <= 24 * 60
            && TimeZone(identifier: timezone) != nil
    }

    var endMinute: Int { startMinute + durationMinutes }

    /// The JSON the `meeting_groups.schedule_json` column and the synced
    /// record carry; keys sorted so the same schedule is the same bytes.
    var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(jsonString: String?) {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MeetingSchedule.self, from: data) else { return nil }
        self = decoded
    }
}

struct MeetingMetadata: Codable, Equatable, Hashable, Sendable {
    var title: String?
    var driveFolderURL: String?
    var localFolderPath: String?
    var recurrenceRule: String?
    var timezone: String?
    var isHidden: Bool = false
    /// A retired provider/group identity that now feeds another meeting group.
    /// The row remains durable so future plugin deliveries can follow the
    /// alias instead of recreating the group the learner merged away.
    var mergedIntoGroupID: String?
    /// When the series meets, so the Planner draws its occurrence on every
    /// day it covers. Nil for a series that has no fixed time.
    var schedule: MeetingSchedule?

    init(
        title: String? = nil,
        driveFolderURL: String? = nil,
        localFolderPath: String? = nil,
        recurrenceRule: String? = nil,
        timezone: String? = nil,
        isHidden: Bool = false,
        mergedIntoGroupID: String? = nil,
        schedule: MeetingSchedule? = nil
    ) {
        self.title = title
        self.driveFolderURL = driveFolderURL
        self.localFolderPath = localFolderPath
        self.recurrenceRule = recurrenceRule
        self.timezone = timezone
        self.isHidden = isHidden
        self.mergedIntoGroupID = mergedIntoGroupID
        self.schedule = schedule
    }
}

extension MeetingMetadata {
    /// `meetingFolder.image.<groupID>` — the sidebar tile the learner picked for
    /// one meeting folder.
    ///
    /// A synced preference rather than a column on `meeting_groups`: this is
    /// display chrome, not a fact about the meeting, and one row per folder keeps
    /// two Macs choosing images for two different folders from overwriting each
    /// other the way a single shared map would.
    static let folderImagePreferenceKeyPrefix = "meetingFolder.image."

    static func folderImagePreferenceKey(for groupID: String) -> String {
        folderImagePreferenceKeyPrefix + groupID
    }
}

enum MeetingArtifactKind: String, Codable, CaseIterable, Sendable {
    case transcript
    case notes
    case chat
    case recording
    case attachment

    var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .notes: return "Notes"
        case .chat: return "Chat"
        case .recording: return "Recording"
        case .attachment: return "Attachment"
        }
    }

    var sortRank: Int {
        switch self {
        case .transcript: return 0
        case .notes: return 1
        case .chat: return 2
        case .recording: return 3
        case .attachment: return 4
        }
    }

    var iconName: String {
        switch self {
        case .transcript: return "text.alignleft"
        case .notes: return "note.text"
        case .chat: return "bubble.left.and.bubble.right"
        case .recording: return "play.rectangle"
        case .attachment: return "paperclip"
        }
    }
}

/// Pure construction of the merged meeting document stored on a source. Both
/// the app and MCP use this one implementation so generating a transcript can
/// never overwrite notes that arrived from Google Drive.
enum MeetingContent {
    nonisolated static func contains(
        section kind: MeetingArtifactKind,
        in content: String?
    ) -> Bool {
        guard let content, !content.isEmpty else { return false }
        return content.range(of: "\n## \(kind.label)\n") != nil
    }

    nonisolated static func text(
        for section: MeetingArtifactKind,
        in content: String?
    ) -> String? {
        guard let content,
              let start = content.range(of: "\n## \(section.label)\n") else { return nil }
        var end = content.endIndex
        for other in MeetingArtifactKind.allCases where other != section {
            if let range = content.range(
                of: "\n## \(other.label)\n",
                range: start.upperBound..<content.endIndex
            ), range.lowerBound < end {
                end = range.lowerBound
            }
        }
        let text = content[start.upperBound..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated static func inserting(
        section kind: MeetingArtifactKind,
        text: String,
        into content: String?,
        title: String
    ) -> String {
        var base = (content?.isEmpty == false) ? content! : "# \(title)"

        if let start = base.range(of: "\n## \(kind.label)\n") {
            var end = base.endIndex
            for other in MeetingArtifactKind.allCases where other != kind {
                if let range = base.range(
                    of: "\n## \(other.label)\n",
                    range: start.upperBound..<base.endIndex
                ), range.lowerBound < end {
                    end = range.lowerBound
                }
            }
            base.replaceSubrange(start.lowerBound..<end, with: "")
        }

        var insertAt = base.endIndex
        for other in MeetingArtifactKind.allCases where other.sortRank > kind.sortRank {
            if let range = base.range(of: "\n## \(other.label)\n"), range.lowerBound < insertAt {
                insertAt = range.lowerBound
            }
        }
        let body = "\n\n## \(kind.label)\n\n\(text)"
        base.insert(contentsOf: insertAt == base.endIndex ? body : body + "\n", at: insertAt)
        return base
    }
}

/// One thing a meeting session's transcript asked someone to do. Extracted
/// once per session by `AITask.meetingActionItems`; the id is the app's
/// (`<source id>#<position>`), never the model's, so a re-run can only ever
/// land on the same rows. `doneAt` is set by the learner and only ever set,
/// which is what lets two Macs' copies union.
struct MeetingActionItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var groupID: String
    var sourceID: String
    var position: Int
    var text: String
    var owner: String?
    var dueHint: String?
    var doneAt: Date?
    var createdAt: Date
    var updatedAt: Date

    static func makeID(sourceID: String, position: Int) -> String {
        "\(sourceID)#\(position)"
    }

    var isDone: Bool { doneAt != nil }

    init(
        groupID: String,
        sourceID: String,
        position: Int,
        text: String,
        owner: String? = nil,
        dueHint: String? = nil,
        doneAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = Self.makeID(sourceID: sourceID, position: position)
        self.groupID = groupID
        self.sourceID = sourceID
        self.position = position
        self.text = text
        self.owner = owner
        self.dueHint = dueHint
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MeetingArtifact: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var sourceId: String
    var groupId: String
    var kind: MeetingArtifactKind
    var title: String
    var url: String?
    var localFilePath: String?
    var mimeType: String?
    var modifiedAt: Date?
    var sortIndex: Int

    init(
        id: String = UUID().uuidString,
        sourceId: String,
        groupId: String,
        kind: MeetingArtifactKind,
        title: String,
        url: String? = nil,
        localFilePath: String? = nil,
        mimeType: String? = nil,
        modifiedAt: Date? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.sourceId = sourceId
        self.groupId = groupId
        self.kind = kind
        self.title = title
        self.url = url
        self.localFilePath = localFilePath
        self.mimeType = mimeType
        self.modifiedAt = modifiedAt
        self.sortIndex = sortIndex
    }
}

/// Which service a meeting session arrived from.
///
/// Meetings are one source family with several feeds behind it: a Google Drive
/// folder of Meet recordings, Read AI's ingest plugin, a Zoom cloud
/// recording link, or a folder imported from this Mac. Provider is a fact about
/// the *session*, read off its
/// discovery origin — never off whichever tab happens to be showing. That is
/// what lets one recurring series carry sessions from more than one provider
/// and still be a single row, instead of being listed once per provider.
///
/// Adding a provider should mean one case here plus one ingest entry point, and
/// no new presentation code.
enum MeetingProvider: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case googleDrive
    case readAI
    case zoom
    /// A folder imported from this Mac, and the home for sessions pushed in
    /// over MCP without a provider hint. Naming it honestly matters: these used
    /// to be filed under Google Drive because the split tabs left them with
    /// nowhere else to go, which claimed a Drive connection that did not exist.
    case localFolder

    var id: String { rawValue }

    static func forOrigin(_ origin: DiscoveryOrigin?) -> MeetingProvider {
        switch origin {
        case .readAI: return .readAI
        case .googleDriveMeetings: return .googleDrive
        case .zoom: return .zoom
        default: return .localFolder
        }
    }

    /// Maps an authenticated plugin's registered display name onto a meeting
    /// provider. This is intentionally constrained to the provider catalog: an
    /// arbitrary plugin label can never spoof a discovery origin, while a
    /// branded meeting plugin is no longer misfiled as a local folder.
    static func forPluginLabel(_ label: String) -> MeetingProvider? {
        allCases.first { $0.matches(connectorLabel: label) }
    }

    /// Whether a plugin's registered name claims this provider.
    ///
    /// A plugin names itself, and that name is what every source it adds
    /// carries. The guide's worked example registers as "Read AI Meetings", and
    /// an assistant following the recipe picks something like it, so the claim
    /// is the brand as the name's leading word(s). Exact equality was the bug:
    /// a healthy "Read AI Meetings" plugin counted as no Read AI plugin
    /// at all, so the Meetings tab reported Read AI disconnected while its
    /// meetings were filed under Local Folder. Still bounded to the catalog: a
    /// name has to lead with a provider's brand to claim it, and "Zoomer" or
    /// "Read" claim nothing.
    func matches(connectorLabel label: String) -> Bool {
        guard isPlugin else { return false }
        let labelWords = Self.brandWords(label)
        let brand = Self.brandWords(displayName)
        guard !labelWords.isEmpty, !brand.isEmpty else { return false }
        if labelWords.starts(with: brand) { return true }
        // The brand written as one word: "ReadAI sync".
        return labelWords.first == brand.joined()
    }

    private static func brandWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    var pluginDiscoveryOrigin: DiscoveryOrigin? {
        switch self {
        case .readAI: return .readAI
        case .zoom: return .zoom
        case .googleDrive, .localFolder: return nil
        }
    }

    /// Distinct providers behind a set of origins, in stable presentation order
    /// so a series feeding from two providers badges them identically wherever
    /// it is drawn.
    static func providers(for origins: some Sequence<DiscoveryOrigin?>) -> [MeetingProvider] {
        Set(origins.map(forOrigin)).sorted { $0.sortRank < $1.sortRank }
    }

    var sortRank: Int {
        switch self {
        case .googleDrive: return 0
        case .readAI: return 1
        case .zoom: return 2
        case .localFolder: return 3
        }
    }

    /// The providers a series row wears as marks.
    ///
    /// Local Folder is the home for whatever arrived without a provider — a
    /// recording added from this Mac, a transcript pushed over MCP with no
    /// hint — not a service the series is synced with. Next to a Zoom or Drive
    /// mark it said nothing the brand mark did not already say, and read as a
    /// second, unexplained service. So it is drawn only when it is the only
    /// answer. The provider filter keeps the full list: a series with local
    /// recordings still matches a Local Folder filter.
    static func marks(for providers: [MeetingProvider]) -> [MeetingProvider] {
        let branded = providers.filter { $0 != .localFolder }
        return branded.isEmpty ? providers : branded
    }

    var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .readAI: return "Read AI"
        case .zoom: return "Zoom"
        case .localFolder: return "Local Folder"
        }
    }

    /// Full-color brand logo, rendered in place of the SF Symbol when present.
    /// These are the same assets the split Google Drive and Read AI tabs used
    /// to carry in the tab strip: the brand marks did not go away with the
    /// tabs, they moved down onto the rows where they say something per-item.
    var iconAsset: String? {
        switch self {
        case .googleDrive: return "GoogleDriveIcon"
        case .readAI: return "ReadAIIcon"
        case .zoom: return "ZoomIcon"
        case .localFolder: return nil
        }
    }

    var icon: String {
        switch self {
        case .googleDrive: return "folder"
        case .readAI: return "waveform"
        case .zoom: return "video"
        case .localFolder: return "internaldrive"
        }
    }

    var color: Color {
        switch self {
        case .googleDrive: return .blue
        case .readAI: return .indigo
        case .zoom: return .blue
        case .localFolder: return .secondary
        }
    }

    /// Whether this provider arrives through a registered MCP ingest client
    /// rather than a first-party sign-in or a local folder. Settings uses it to
    /// decide which providers earn a branded card under Your Plugins — a
    /// question that used to be answered by the tab list, which is why merging
    /// the tabs would otherwise have cost Read AI its card.
    var isPlugin: Bool {
        switch self {
        case .readAI, .zoom: return true
        case .googleDrive, .localFolder: return false
        }
    }

    /// One line for the provider's card in Settings.
    var pluginSubtitle: String {
        switch self {
        case .googleDrive: return "Import meeting recordings and transcripts from a folder."
        case .readAI: return "Add meeting transcripts through your plugin."
        case .zoom: return "Transcripts Zoom saves to Documents/Zoom file themselves; cloud recordings arrive through your plugin."
        case .localFolder: return "Import a folder of recordings from this Mac."
        }
    }

    /// What the plugin setup prompt carries when the Meetings tab copies it
    /// for this provider: the part of the guide's worked example an assistant
    /// needs and would otherwise have to discover, including the name that
    /// makes ForeverLM file the plugin's meetings under the provider. Empty
    /// for providers that don't arrive through a plugin.
    var pluginSetupNotes: String {
        switch self {
        case .readAI:
            return """
            Notes for Read AI: register the plugin with a "client_name" that starts with "Read AI" (for example "Read AI Meetings") so ForeverLM files its meetings under Read AI. Read AI's API uses OAuth 2.1 with PKCE and rotating, single-use refresh tokens — persist each new refresh token the instant it is issued and never let two runs overlap. Request the scopes openid email profile offline_access meeting:read mcp:execute; its REST API rejects a token minted from a narrower set with "Invalid audience". My workspace needs Downloads enabled under Workspace Settings → Reports & Sharing. List recent ended meetings, fetch each one's summary and speaker-attributed transcript, and push one source per meeting with source_type "meeting", the organizer as author, https://app.read.ai/analytics/meetings/<meeting id> as its stable url, occurred_at from the meeting's start time (ISO 8601), and parent_group set to the series name — the title with tags like "[EF]" and any trailing date stripped — so each meeting files inside its recurring series. Re-examine the last few days on every run so late-arriving transcripts are picked up, and call report_connector_status at the start and end of every run so ForeverLM can show the plugin's health.
            """
        case .zoom:
            return """
            Notes for Zoom: register the plugin with a "client_name" that starts with "Zoom" so ForeverLM files its recordings under Zoom. List my cloud recordings, fetch each transcript, and push one source per recording with source_type "meeting" and the recording's share link as its stable url. Call report_connector_status at the start and end of every run so ForeverLM can show the plugin's health.
            """
        case .googleDrive, .localFolder:
            return ""
        }
    }
}
