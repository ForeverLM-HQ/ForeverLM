import AppKit
import CloudKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import PDFKit
import UniformTypeIdentifiers

enum CloudKitSyncEntity: String, CaseIterable, Sendable {
    case source
    case sourceHighlight
    case book
    case course
    case videoPlaylist
    case meetingGroup
    case hiddenSource
    case hiddenPodcastShow
    case hiddenYouTubeChannel
    /// A doc or site the learner hid from the Docs and Sites lists, keyed by
    /// the artifact's id. Homed in the learner's private zone whatever zone
    /// the Artifact itself lives in: hiding is the learner's view of the
    /// record, which every Mac signed into the account shares and no
    /// teammate sees (teams-design.md, per-member state never enters a team
    /// record). Schema gate: create `HiddenArtifact` with `payload` and
    /// `userModificationDate` in Development, then deploy it to Production
    /// before shipping the build that writes it.
    case hiddenArtifact
    /// A chat the learner hid from the sidebar; the same shape and the same
    /// schema gate as `hiddenArtifact`, as `HiddenReviewSession`.
    case hiddenReviewSession
    case dismissedSource
    case chatContext
    case reviewSession
    case memoryItem
    case memoryAttempt
    case sourceIdea
    case memoryReviewActivity
    case learningGoal
    case artifact
    case artifactComment
    case scheduledSource
    case scheduledTask
    /// One local date's time-block plan with every block it has held. Schema
    /// gate: create `DayPlan` with `payload` and `userModificationDate` in
    /// Development, then deploy it to Production before shipping the planner.
    case dayPlan
    /// An Idea the learner jotted down, with its links, in one record
    /// (docs/ideas-design.md). Schema gate: create `Idea` with `payload` and
    /// `userModificationDate` in Development, then deploy it to Production
    /// before shipping the Ideas tab.
    case idea
    /// Where the learner is in one walkthrough and how its questions went
    /// (walkthrough-design.md, "the walk leaves the chat"). Private zone
    /// only. Schema gate: create `WalkthroughProgress` with `payload` and
    /// `userModificationDate` in Development, then deploy it to Production
    /// before shipping schema 133.
    case walkthroughProgress
    /// One of the learner's chat skills (chat-design.md, "Skills"). Private
    /// zone only. Schema gate: create `Skill` with `payload` and
    /// `userModificationDate` in Development, then deploy it to Production
    /// before shipping schema 136.
    case skill
    /// A Direction a search proposed toward a Goal, Notebook or Idea, with
    /// its evidence and the learner's answer, in one record
    /// (docs/directions-design.md). Private zone only. Schema gate: create
    /// `ResearchDirection` with `payload` and `userModificationDate` in
    /// Development, then deploy it to Production before shipping schema 147.
    case researchDirection
    case videoCitedPaper
    case researchCanvas
    case aiUsageEvent
    case preference
    /// A team's own record: its name and creation details, homed in the team
    /// zone so every member sees the same name. Schema gate: create `Team`
    /// with `payload` and `userModificationDate` in Development, then deploy
    /// it to Production before shipping the teams build.
    case team
    /// One task on a Notebook's board. Same schema gate as `team`. Its raw value
    /// and record type keep the name they were uploaded under: record names are
    /// derived from the raw value, so renaming it would re-key every task record.
    case notebookTask = "projectTask"
    /// A member's request that a cited source be shared into the team. Same
    /// schema gate as `team`.
    case shareRequest

    var recordType: String {
        switch self {
        case .source:
            return "Source"
        case .sourceHighlight:
            return "SourceHighlight"
        case .book:
            return "Book"
        case .course:
            return "Course"
        case .videoPlaylist:
            return "VideoPlaylist"
        case .meetingGroup:
            return "MeetingGroup"
        case .hiddenSource:
            return "HiddenSource"
        case .hiddenPodcastShow:
            return "HiddenPodcastShow"
        case .hiddenYouTubeChannel:
            return "HiddenYouTubeChannel"
        case .hiddenArtifact:
            return "HiddenArtifact"
        case .hiddenReviewSession:
            return "HiddenReviewSession"
        case .dismissedSource:
            return "DismissedSource"
        case .chatContext:
            return "ChatContext"
        case .reviewSession:
            return "ReviewSession"
        case .memoryItem:
            return "MemoryItem"
        case .memoryAttempt:
            return "MemoryAttempt"
        case .sourceIdea:
            return "SourceIdea"
        case .memoryReviewActivity:
            return "MemoryReviewActivity"
        case .learningGoal:
            return "LearningGoal"
        case .artifact:
            return "Artifact"
        case .artifactComment:
            return "ArtifactComment"
        case .scheduledSource:
            return "ScheduledSource"
        case .scheduledTask:
            return "ScheduledTask"
        case .dayPlan:
            return "DayPlan"
        case .idea:
            return "Idea"
        case .walkthroughProgress:
            return "WalkthroughProgress"
        case .skill:
            return "Skill"
        case .researchDirection:
            return "ResearchDirection"
        case .videoCitedPaper:
            return "VideoCitedPaper"
        case .researchCanvas:
            return "ResearchCanvas"
        case .aiUsageEvent:
            return "AIUsageEvent"
        case .preference:
            return "Preference"
        case .team:
            return "Team"
        case .notebookTask:
            return "ProjectTask"
        case .shareRequest:
            return "ShareRequest"
        }
    }

    static func from(recordType: String) -> CloudKitSyncEntity? {
        allCases.first(where: { $0.recordType == recordType })
    }
}

enum CloudKitSyncOperation: String, Sendable, Equatable {
    case save
    case delete
}

enum CloudKitSyncDigestField {
    /// Decode-only key left behind by builds that carried Markdown in the
    /// encrypted payload. New Article bodies use the payloadAsset CKAsset.
    static let legacyArtifactMarkdownPayload = "artifactMarkdownPayload"
}

struct CloudKitPendingChange: Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let recordName: String
    let operation: CloudKitSyncOperation
    let changedAt: Date
    /// The zone the change is sent to. Defaults to the learner's own zone so
    /// the many existing constructors keep meaning what they always meant.
    let home: CloudKitZoneHome

    init(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        recordName: String,
        operation: CloudKitSyncOperation,
        changedAt: Date,
        home: CloudKitZoneHome = .knowledge
    ) {
        self.entity = entity
        self.logicalKey = logicalKey
        self.recordName = recordName
        self.operation = operation
        self.changedAt = changedAt
        self.home = home
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: home.zoneID)
    }
}

/// A wholesale re-enqueue — the first bootstrap, or an iCloud sign-in that
/// cleared every record's server identity — has no per-record edit time to
/// carry, so it stamps this instead. The value is chosen to sort a mass
/// republish behind genuine user edits in the outbound queue.
///
/// It is a sort key, not a timestamp. Reading it as one claims the change was
/// made in 2001: Settings rendered a container rename's re-upload as "25 yrs,
/// 8 mths" and flagged all of it stale, when the rows had been queued minutes
/// earlier. Anything that formats a pending change's date, or measures how long
/// one has waited, must check this first.
enum CloudKitSyncBootstrapStamp {
    static let date = Date(timeIntervalSinceReferenceDate: 0)

    static func isBootstrap(_ date: Date) -> Bool {
        date <= Self.date
    }
}

struct CloudKitSyncPendingItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: String
    let operation: CloudKitSyncOperation
    let changedAt: Date
}

struct CloudKitSyncIssueItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: String
    let operation: CloudKitSyncOperation
    let message: String
    let detectedAt: Date
}

/// Asset staging that CloudKit has neither accepted nor rejected, aggregated
/// store-wide and already filtered by age and attempt count. `none` is the
/// healthy answer, not a missing one.
struct CloudKitStalledAssetStaging: Equatable, Sendable {
    let recordCount: Int
    let fieldCount: Int
    let oldestStagedAt: Date?
    let maxAttempts: Int

    static let none = CloudKitStalledAssetStaging(
        recordCount: 0,
        fieldCount: 0,
        oldestStagedAt: nil,
        maxAttempts: 0
    )

    var isEmpty: Bool { recordCount == 0 }
}

struct CloudKitSyncMetadata: Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let recordName: String
    let systemFieldsData: Data?
    let userModificationDate: Date
    let isDeleted: Bool
    let home: CloudKitZoneHome

    init(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        recordName: String,
        systemFieldsData: Data?,
        userModificationDate: Date,
        isDeleted: Bool,
        home: CloudKitZoneHome = .knowledge
    ) {
        self.entity = entity
        self.logicalKey = logicalKey
        self.recordName = recordName
        self.systemFieldsData = systemFieldsData
        self.userModificationDate = userModificationDate
        self.isDeleted = isDeleted
        self.home = home
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: home.zoneID)
    }
}

/// A permanent create-once/immutable collision held out of the active upload
/// queue. The app can surface this durable row and a future explicit resolver
/// has both the server payload and change tag it needs; background sync never
/// hot-loops or silently overwrites either winner.
struct CloudKitSyncConflict: Sendable, Equatable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let recordName: String
    let reason: String
    let localModificationDate: Date
    let serverModificationDate: Date
    let detectedAt: Date
    let serverPayload: Data?
    let serverSystemFields: Data?
    let home: CloudKitZoneHome

    init(
        entity: CloudKitSyncEntity,
        logicalKey: String,
        recordName: String,
        reason: String,
        localModificationDate: Date,
        serverModificationDate: Date,
        detectedAt: Date,
        serverPayload: Data?,
        serverSystemFields: Data?,
        home: CloudKitZoneHome = .knowledge
    ) {
        self.entity = entity
        self.logicalKey = logicalKey
        self.recordName = recordName
        self.reason = reason
        self.localModificationDate = localModificationDate
        self.serverModificationDate = serverModificationDate
        self.detectedAt = detectedAt
        self.serverPayload = serverPayload
        self.serverSystemFields = serverSystemFields
        self.home = home
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: home.zoneID)
    }
}

extension CloudKitZoneHome {
    /// The CloudKit address of this home. A private-scope home belongs to the
    /// current user; a shared-scope home names the zone's owner.
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: ownerRecordName ?? CKCurrentUserDefaultName
        )
    }

    /// The home of a record that arrived from `zoneID` through the database
    /// with `scope`. The private database only ever carries the current
    /// user's zones, so the owner is dropped there.
    init(zoneID: CKRecordZone.ID, scope: Scope) {
        self.init(
            scope: scope,
            zoneName: zoneID.zoneName,
            ownerRecordName: scope == .shared ? zoneID.ownerName : nil
        )
    }
}

/// A team's own record. The zone is the team; this is the row that names it.
struct CloudKitTeamPayload: Codable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    /// The creator's display name, kept beside the record so a member's
    /// roster reads well before the share participants have been fetched.
    let createdByDisplayName: String?
    /// The family plan code, while the owner's plan covers the team
    /// (`TeamRecord.familyPlanCode`). Absent from records written before
    /// schema 137, which decode as no family.
    let familyPlanCode: String?

    init(
        id: String,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        createdByDisplayName: String? = nil,
        familyPlanCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdByDisplayName = createdByDisplayName
        self.familyPlanCode = familyPlanCode
    }
}

struct CloudKitNotebookTaskPayload: Codable, Sendable {
    let task: NotebookTaskRecord
}

struct CloudKitShareRequestPayload: Codable, Sendable {
    let request: ShareRequestRecord
}

/// A direct-fetch retry for a valid browser-authored PDF whose CKAsset or local
/// destination was temporarily unavailable. It deliberately reuses the
/// existing durable `sync_conflicts` envelope: unlike a permanent conflict,
/// these rows are hidden from the conflict surface and never suppress local
/// outbound work.
struct CloudKitInboundWebPDFRetry: Sendable, Equatable {
    static let reasonPrefix = "ForeverLMInboundWebPDFRetryV1:"
    static let reasonLikePattern = reasonPrefix + "%"
    static let quarantineReasonPrefix = "ForeverLMInboundWebPDFQuarantineV1: "

    let entity: CloudKitSyncEntity
    let logicalKey: String
    let recordName: String
    let failureReason: String
    let attemptCount: Int
    let nextAttemptAt: Date
    let serverModificationDate: Date
    let firstFailedAt: Date
    let serverPayload: Data?
    let serverSystemFields: Data?

    static func encodedReason(attemptCount: Int, failureReason: String) -> String {
        reasonPrefix + String(max(1, attemptCount)) + "\n" + failureReason
    }

    static func decodedReason(_ storedReason: String) -> (attemptCount: Int, failureReason: String)? {
        guard storedReason.hasPrefix(reasonPrefix) else { return nil }
        let remainder = storedReason.dropFirst(reasonPrefix.count)
        let fields = remainder.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let first = fields.first, let attemptCount = Int(first), attemptCount > 0 else {
            return nil
        }
        let failureReason = fields.count == 2
            ? String(fields[1])
            : "CloudKit web PDF retry pending."
        return (attemptCount, failureReason)
    }

    static func retryDelay(afterAttempt attemptCount: Int) -> TimeInterval {
        switch attemptCount {
        case ...1: return 5
        case 2: return 30
        case 3: return 2 * 60
        case 4: return 10 * 60
        default: return 60 * 60
        }
    }
}

/// A save the server refused for a reason retrying cannot fix on its own — a
/// record type missing from the deployed schema, a rejected request, a failed
/// server-side validation. Left in the queue, one such record wedges the whole
/// engine: the pending count never reaches zero, so the status indicator shows
/// a permanent warning, `sendChanges()` keeps throwing (which also skips the
/// fetch paired with it), and the retry loop runs until the app quits. Parking
/// the record in
/// `sync_conflicts` bounds that to a single failure while keeping the local row
/// and its payload untouched.
///
/// These rows are re-armed at engine start and by an explicit "Retry now", so the
/// usual cause — a record type still awaiting a Production schema deploy — heals
/// itself once the environment is fixed, with no manual database surgery.
enum CloudKitRejectedSaveQuarantine {
    static let reasonPrefix = "ForeverLMRejectedSaveV1:"
    static let reasonLikePattern = reasonPrefix + "%"

    static func encodedReason(errorCode: Int, message: String) -> String {
        reasonPrefix + String(errorCode) + "\n" + message
    }

    static func decodedReason(_ storedReason: String) -> (errorCode: Int, message: String)? {
        guard storedReason.hasPrefix(reasonPrefix) else { return nil }
        let fields = storedReason
            .dropFirst(reasonPrefix.count)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = fields.first, let errorCode = Int(first) else { return nil }
        let message = fields.count == 2
            ? String(fields[1])
            : "iCloud refused this record."
        return (errorCode, message)
    }
}

/// A locally prepared save or delete that cannot be sent successfully and must
/// leave the hot retry queue. This complements the original save-only envelope:
/// deletes need to remember that they are deletes when an explicit retry re-arms
/// them, and local record-construction failures do not have a CKError code.
enum CloudKitRejectedChangeQuarantine {
    static let reasonPrefix = "ForeverLMRejectedChangeV1:"
    static let reasonLikePattern = reasonPrefix + "%"

    static func encodedReason(
        operation: CloudKitSyncOperation,
        errorCode: Int?,
        message: String
    ) -> String {
        let code = errorCode.map(String.init) ?? "-"
        return reasonPrefix + operation.rawValue + "\n" + code + "\n" + message
    }

    static func decodedReason(
        _ storedReason: String
    ) -> (operation: CloudKitSyncOperation, errorCode: Int?, message: String)? {
        guard storedReason.hasPrefix(reasonPrefix) else { return nil }
        let fields = storedReason
            .dropFirst(reasonPrefix.count)
            .split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2,
              let operation = CloudKitSyncOperation(rawValue: String(fields[0])) else {
            return nil
        }
        let errorCode = fields[1] == "-" ? nil : Int(fields[1])
        let message = fields.count == 3
            ? String(fields[2])
            : "iCloud refused this change."
        return (operation, errorCode, message)
    }
}

struct CloudKitRecordDescriptor: Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let userModificationDate: Date
}

struct CloudKitAppliedRecord: Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let userModificationDate: Date
    let requiresRepublish: Bool
}

struct CloudKitSourcePayload: Codable, Sendable {
    static let currentVersion = 1

    let payloadVersion: Int
    let article: StudioArticle
    /// Portable deterministic identity derived from the canonical source rows.
    /// In particular, `publishedDOI` travels here rather than in the encoded
    /// article: `StudioArticle` carries it in memory but keeps it out of
    /// `CodingKeys`, so this payload stays its only wire representation.
    let sourceIdentity: CloudKitSourceIdentityPayload?
    let visiblePodcastEpisodeOverride: Bool
    let visibleYouTubeVideoOverride: Bool
    let sourceUnits: [SourceUnit]
    let hasSourceUnitsPayload: Bool
    let paperContentPreparation: PaperContentPreparationMetadata?
    let articleContentPreparation: PaperContentPreparationMetadata?
    let podcastTranscriptCleanup: PodcastTranscriptCleanupMetadata?
    let listenableContentMetadata: SourceListenableContentMetadata?
    let hasListenableContentPayload: Bool
    let sourceReviewGuide: SourceReviewGuide?
    /// The paper's guided walkthrough (walkthrough-design.md). Absent from a
    /// payload written by a client that predates it, which means "leave the
    /// local one alone", never "it is gone".
    let paperWalkthrough: PaperWalkthrough?
    let paperFigures: [SyncedPaperFigure]
    let hasPaperFiguresPayload: Bool
    /// Browser-created files have no iCloud Documents writer of their own. These
    /// optional envelope fields distinguish that one ingestion path from the
    /// ordinary Mac -> iOS `sourcePDFAsset` compatibility feed.
    let webFileName: String?
    let webFileKind: String?
    /// The source's memory-review depth (`MemoryReviewDepth`), nil when unset
    /// or when the payload came from a client that predates it; both mean
    /// "leave the local value alone".
    let reviewDepth: String?

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case article
        case sourceIdentity
        case visiblePodcastEpisodeOverride
        case visibleYouTubeVideoOverride
        case sourceUnits
        case paperContentPreparation
        case articleContentPreparation
        case podcastTranscriptCleanup
        case listenableContentMetadata
        case sourceReviewGuide
        case paperWalkthrough
        case paperFigures
        case webFileName
        case webFileKind
        case reviewDepth
    }

    init(
        article: StudioArticle,
        sourceIdentity: CloudKitSourceIdentityPayload? = nil,
        visiblePodcastEpisodeOverride: Bool = false,
        visibleYouTubeVideoOverride: Bool = false,
        sourceUnits: [SourceUnit] = [],
        paperContentPreparation: PaperContentPreparationMetadata? = nil,
        articleContentPreparation: PaperContentPreparationMetadata? = nil,
        podcastTranscriptCleanup: PodcastTranscriptCleanupMetadata? = nil,
        listenableContentMetadata: SourceListenableContentMetadata? = nil,
        sourceReviewGuide: SourceReviewGuide? = nil,
        paperWalkthrough: PaperWalkthrough? = nil,
        paperFigures: [SyncedPaperFigure] = [],
        webFileName: String? = nil,
        webFileKind: String? = nil,
        reviewDepth: String? = nil
    ) {
        self.payloadVersion = Self.currentVersion
        self.article = article
        self.sourceIdentity = sourceIdentity
        self.visiblePodcastEpisodeOverride = visiblePodcastEpisodeOverride
        self.visibleYouTubeVideoOverride = visibleYouTubeVideoOverride
        self.sourceUnits = sourceUnits
        self.hasSourceUnitsPayload = true
        self.paperContentPreparation = paperContentPreparation
        self.articleContentPreparation = articleContentPreparation
        self.podcastTranscriptCleanup = podcastTranscriptCleanup
        self.listenableContentMetadata = listenableContentMetadata
        self.hasListenableContentPayload = true
        self.sourceReviewGuide = sourceReviewGuide
        self.paperWalkthrough = paperWalkthrough
        self.paperFigures = paperFigures
        self.hasPaperFiguresPayload = true
        self.webFileName = webFileName
        self.webFileKind = webFileKind
        self.reviewDepth = reviewDepth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        article = try container.decode(StudioArticle.self, forKey: .article)
        sourceIdentity = try container.decodeIfPresent(
            CloudKitSourceIdentityPayload.self,
            forKey: .sourceIdentity
        )
        visiblePodcastEpisodeOverride = try container.decodeIfPresent(Bool.self, forKey: .visiblePodcastEpisodeOverride) ?? false
        visibleYouTubeVideoOverride = try container.decodeIfPresent(Bool.self, forKey: .visibleYouTubeVideoOverride) ?? false
        hasSourceUnitsPayload = container.contains(.sourceUnits)
        sourceUnits = try container.decodeIfPresent([SourceUnit].self, forKey: .sourceUnits) ?? []
        paperContentPreparation = try container.decodeIfPresent(PaperContentPreparationMetadata.self, forKey: .paperContentPreparation)
        articleContentPreparation = try container.decodeIfPresent(PaperContentPreparationMetadata.self, forKey: .articleContentPreparation)
        podcastTranscriptCleanup = try container.decodeIfPresent(
            PodcastTranscriptCleanupMetadata.self,
            forKey: .podcastTranscriptCleanup
        )
        hasListenableContentPayload = container.contains(.listenableContentMetadata)
        listenableContentMetadata = try container.decodeIfPresent(
            SourceListenableContentMetadata.self,
            forKey: .listenableContentMetadata
        )
        sourceReviewGuide = try container.decodeIfPresent(SourceReviewGuide.self, forKey: .sourceReviewGuide)
        paperWalkthrough = try container.decodeIfPresent(PaperWalkthrough.self, forKey: .paperWalkthrough)
        hasPaperFiguresPayload = container.contains(.paperFigures)
        paperFigures = try container.decodeIfPresent([SyncedPaperFigure].self, forKey: .paperFigures) ?? []
        webFileName = try container.decodeIfPresent(String.self, forKey: .webFileName)
        webFileKind = try container.decodeIfPresent(String.self, forKey: .webFileKind)
        reviewDepth = try container.decodeIfPresent(String.self, forKey: .reviewDepth)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payloadVersion, forKey: .payloadVersion)
        try container.encode(article, forKey: .article)
        try container.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
        try container.encode(visiblePodcastEpisodeOverride, forKey: .visiblePodcastEpisodeOverride)
        try container.encode(visibleYouTubeVideoOverride, forKey: .visibleYouTubeVideoOverride)
        try container.encode(sourceUnits, forKey: .sourceUnits)
        try container.encodeIfPresent(paperContentPreparation, forKey: .paperContentPreparation)
        try container.encodeIfPresent(articleContentPreparation, forKey: .articleContentPreparation)
        try container.encodeIfPresent(podcastTranscriptCleanup, forKey: .podcastTranscriptCleanup)
        try container.encode(listenableContentMetadata, forKey: .listenableContentMetadata)
        try container.encodeIfPresent(sourceReviewGuide, forKey: .sourceReviewGuide)
        try container.encodeIfPresent(paperWalkthrough, forKey: .paperWalkthrough)
        try container.encode(paperFigures, forKey: .paperFigures)
        try container.encodeIfPresent(webFileName, forKey: .webFileName)
        try container.encodeIfPresent(webFileKind, forKey: .webFileKind)
        try container.encodeIfPresent(reviewDepth, forKey: .reviewDepth)
    }
}

struct CloudKitBookPayload: Codable, Sendable {
    let id: String
    let name: String
    let title: String
    let subtitle: String?
    let author: String?
    let edition: String?
    let coverPath: String?
    let kind: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case subtitle
        case author
        case edition
        case coverPath
        case kind
    }

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        author: String?,
        edition: String? = nil,
        coverPath: String?,
        kind: String? = nil
    ) {
        self.id = id
        self.name = title
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.edition = edition
        self.coverPath = coverPath
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? decodedName
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id) ?? decodedName
        guard let idValue = decodedID, let titleValue = decodedTitle else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Book payload is missing title")
            )
        }
        id = idValue
        title = titleValue
        name = decodedName ?? titleValue
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        edition = try container.decodeIfPresent(String.self, forKey: .edition)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(edition, forKey: .edition)
        try container.encodeIfPresent(coverPath, forKey: .coverPath)
        try container.encodeIfPresent(kind, forKey: .kind)
    }
}

struct CloudKitCoursePayload: Codable, Sendable {
    let id: String
    let name: String
    let courseCode: String?
    let title: String?
    let institution: String?
    let instructors: String?
    let playlistURL: String?
    let isHidden: Bool
    let pendingPlaylistImport: Bool
    let lectures: [CourseSession]
    let lectureItems: [CourseLectureItem]
    /// The course's stored quizzes (schema 138). Nil when the record came
    /// from a build that did not carry them, which must never read as "the
    /// course has no quizzes" and wipe this Mac's.
    let quizzes: [CourseQuiz]?
    /// The page units its lecture items name: a textbook reading's pages
    /// (docs/textbook-readings-design.md). Carried here so a reading lands
    /// with its unit instead of waiting on the chapter's own record. Applied
    /// as upserts before the items, never as a replacement: nil (a build that
    /// did not carry them) and a missing unit both say nothing about a unit.
    let sourceUnits: [SourceUnit]?

    init(
        id: String,
        title: String,
        courseCode: String?,
        institution: String?,
        instructors: String?,
        playlistURL: String?,
        isHidden: Bool = false,
        pendingPlaylistImport: Bool = false,
        lectures: [CourseSession] = [],
        lectureItems: [CourseLectureItem] = [],
        quizzes: [CourseQuiz]? = nil,
        sourceUnits: [SourceUnit]? = nil
    ) {
        self.id = id
        self.name = title
        self.courseCode = courseCode
        self.title = title
        self.institution = institution
        self.instructors = instructors
        self.playlistURL = playlistURL
        self.isHidden = isHidden
        self.pendingPlaylistImport = pendingPlaylistImport
        self.lectures = lectures
        self.lectureItems = lectureItems
        self.quizzes = quizzes
        self.sourceUnits = sourceUnits
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case courseCode
        case title
        case institution
        case instructors
        case playlistURL
        case isHidden
        case pendingPlaylistImport
        case lectures
        case lectureItems
        case quizzes
        case sourceUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let pendingPlaylistImport = try container.decodeIfPresent(
            Bool.self,
            forKey: .pendingPlaylistImport
        ) ?? false
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
            ?? (pendingPlaylistImport ? nil : decodedName)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id) ?? decodedName
        guard let idValue = decodedID else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Course payload is missing identity")
            )
        }
        id = idValue
        name = decodedName ?? decodedTitle ?? idValue
        courseCode = try container.decodeIfPresent(String.self, forKey: .courseCode)
        title = decodedTitle
        institution = try container.decodeIfPresent(String.self, forKey: .institution)
        instructors = try container.decodeIfPresent(String.self, forKey: .instructors)
        playlistURL = try container.decodeIfPresent(String.self, forKey: .playlistURL)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.pendingPlaylistImport = pendingPlaylistImport
        lectures = try container.decodeIfPresent([CourseSession].self, forKey: .lectures) ?? []
        lectureItems = try container.decodeIfPresent([CourseLectureItem].self, forKey: .lectureItems) ?? []
        quizzes = try container.decodeIfPresent([CourseQuiz].self, forKey: .quizzes)
        sourceUnits = try container.decodeIfPresent([SourceUnit].self, forKey: .sourceUnits)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(courseCode, forKey: .courseCode)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(institution, forKey: .institution)
        try container.encodeIfPresent(instructors, forKey: .instructors)
        try container.encodeIfPresent(playlistURL, forKey: .playlistURL)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(pendingPlaylistImport, forKey: .pendingPlaylistImport)
        try container.encode(lectures, forKey: .lectures)
        try container.encode(lectureItems, forKey: .lectureItems)
        try container.encodeIfPresent(quizzes, forKey: .quizzes)
        try container.encodeIfPresent(sourceUnits, forKey: .sourceUnits)
    }
}

struct CloudKitVideoPlaylistPayload: Codable, Sendable {
    let id: String
    let metadata: VideoPlaylistMetadata
}

struct CloudKitMeetingGroupPayload: Codable, Sendable {
    let id: String
    let title: String?
    let driveFolderURL: String?
    let localFolderPath: String?
    let recurrenceRule: String?
    let timezone: String?
    let isHidden: Bool
    let mergedIntoGroupID: String?
    let artifacts: [MeetingArtifact]
    /// When the series meets (schema 113). Optional so a record from an
    /// older client still decodes; an older client decoding this record
    /// drops the key and keeps the rest.
    let schedule: MeetingSchedule?
    /// The sessions' action items (schema 113), beside the artifacts. Nil on
    /// a record from an older client, which is read as "nothing to merge".
    let actionItems: [MeetingActionItem]?

    init(
        id: String,
        metadata: MeetingMetadata,
        artifacts: [MeetingArtifact] = [],
        actionItems: [MeetingActionItem] = []
    ) {
        self.actionItems = actionItems
        self.id = id
        self.title = metadata.title
        self.driveFolderURL = metadata.driveFolderURL
        self.localFolderPath = metadata.localFolderPath
        self.recurrenceRule = metadata.recurrenceRule
        self.timezone = metadata.timezone
        self.isHidden = metadata.isHidden
        self.mergedIntoGroupID = metadata.mergedIntoGroupID
        self.artifacts = artifacts
        self.schedule = metadata.schedule
    }

    var metadata: MeetingMetadata {
        MeetingMetadata(
            title: title,
            driveFolderURL: driveFolderURL,
            localFolderPath: localFolderPath,
            recurrenceRule: recurrenceRule,
            timezone: timezone,
            isHidden: isHidden,
            mergedIntoGroupID: mergedIntoGroupID,
            schedule: schedule
        )
    }
}

struct CloudKitDismissedSourcePayload: Codable, Sendable {
    let url: String
    let title: String?
    let dismissedAt: Date
}

/// One synced user preference. The logical key is the preference key itself, so
/// each setting is its own CloudKit record and two Macs editing two different
/// settings never contend.
///
/// `valuePlistXML` is an XML property list rather than a JSON value because the
/// plist type system *is* the UserDefaults type system: JSON cannot distinguish
/// Bool from Int, and `object(forKey:) as? Bool` returns nil for a value that
/// round-tripped into a plain NSNumber, silently reverting the setting.
struct CloudKitPreferencePayload: Codable, Sendable {
    let key: String
    let valuePlistXML: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case key
        case valuePlistXML
        case updatedAt
    }

    init(key: String, valuePlistXML: String, updatedAt: Date) {
        self.key = key
        self.valuePlistXML = valuePlistXML
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        valuePlistXML = try container.decodeIfPresent(String.self, forKey: .valuePlistXML) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct CloudKitHiddenPodcastShowPayload: Codable, Sendable {
    let showName: String
    let hiddenAt: Date
}

struct CloudKitHiddenYouTubeChannelPayload: Codable, Sendable {
    let channelName: String
    let hiddenAt: Date
}

/// A hidden doc or site (schema 114). The artifact's id and when it was hidden;
/// the record says nothing else about the doc, so a teammate's copy of the
/// Artifact is untouched and a Mac that has not received the Artifact yet
/// keeps the row until it does.
struct CloudKitHiddenArtifactPayload: Codable, Sendable {
    let artifactID: String
    let hiddenAt: Date
}

/// A hidden chat (schema 114); the same contract as `CloudKitHiddenArtifactPayload`.
struct CloudKitHiddenReviewSessionPayload: Codable, Sendable {
    let sessionID: String
    let hiddenAt: Date
}

struct CloudKitHiddenSourcePayload: Codable, Sendable {
    let sourceID: String
    let hiddenAt: Date
    let url: String?
    let normalizedURL: String?

    init(sourceID: String, hiddenAt: Date, url: String? = nil, normalizedURL: String? = nil) {
        self.sourceID = sourceID
        self.hiddenAt = hiddenAt
        self.url = url
        self.normalizedURL = normalizedURL
    }
}

struct CloudKitSourceIdentityPayload: Codable, Sendable {
    let sourceID: String
    let url: String?
    let normalizedURL: String?
    let doi: String?
    let publishedDOI: String?
}

/// One independently mutable reader annotation. Keeping highlights outside the
/// whole Source envelope lets older clients continue saving source metadata
/// without erasing annotations they do not know how to round-trip.
struct CloudKitSourceHighlightPayload: Codable, Sendable {
    static let currentVersion = 1

    let payloadVersion: Int
    let highlight: SourceHighlight
    let sourceIdentity: CloudKitSourceIdentityPayload?

    init(
        payloadVersion: Int = Self.currentVersion,
        highlight: SourceHighlight,
        sourceIdentity: CloudKitSourceIdentityPayload?
    ) {
        self.payloadVersion = payloadVersion
        self.highlight = highlight
        self.sourceIdentity = sourceIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case highlight
        case sourceIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        highlight = try container.decode(SourceHighlight.self, forKey: .highlight)
        sourceIdentity = try container.decodeIfPresent(
            CloudKitSourceIdentityPayload.self,
            forKey: .sourceIdentity
        )
    }
}

/// A MemoryItem is the aggregate sync boundary for all of its source anchors.
/// Portable source identities let another device remap local source primary keys
/// without asking an LLM to decide identity.
struct CloudKitMemoryItemPayload: Codable, Sendable {
    static let currentVersion = 1

    let payloadVersion: Int
    let item: MemoryItem
    let sourceIdentities: [CloudKitSourceIdentityPayload]

    init(
        payloadVersion: Int = Self.currentVersion,
        item: MemoryItem,
        sourceIdentities: [CloudKitSourceIdentityPayload] = []
    ) {
        self.payloadVersion = payloadVersion
        self.item = item
        self.sourceIdentities = sourceIdentities
    }

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case item
        case sourceIdentities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        item = try container.decode(MemoryItem.self, forKey: .item)
        sourceIdentities = try container.decodeIfPresent(
            [CloudKitSourceIdentityPayload].self,
            forKey: .sourceIdentities
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payloadVersion, forKey: .payloadVersion)
        try container.encode(item, forKey: .item)
        try container.encode(sourceIdentities, forKey: .sourceIdentities)
    }
}

/// Attempts are independent, immutable CloudKit records. This avoids last-writer
/// replacement of an item's history when two devices review it concurrently.
struct CloudKitMemoryAttemptPayload: Codable, Sendable {
    static let currentVersion = 2

    let payloadVersion: Int
    let attempt: MemoryAttempt
    /// Immutable parent snapshot used to validate cross-delta delivery. Older
    /// clients omit it; current writers always populate it from SQLite.
    let parentCurriculumFingerprint: String?

    init(
        payloadVersion: Int? = nil,
        attempt: MemoryAttempt,
        parentCurriculumFingerprint: String? = nil
    ) {
        // `attempt:` alone is the source-compatible legacy fixture/import
        // shape. Current production writers always provide a fingerprint and
        // therefore emit v2; callers can still construct an explicitly malformed
        // v2 payload to verify fail-closed decoding.
        self.payloadVersion = payloadVersion
            ?? (parentCurriculumFingerprint == nil ? 1 : Self.currentVersion)
        self.attempt = attempt
        self.parentCurriculumFingerprint = parentCurriculumFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case attempt
        case parentCurriculumFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try container.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        attempt = try container.decode(MemoryAttempt.self, forKey: .attempt)
        parentCurriculumFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .parentCurriculumFingerprint
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payloadVersion, forKey: .payloadVersion)
        try container.encode(attempt, forKey: .attempt)
        try container.encodeIfPresent(
            parentCurriculumFingerprint,
            forKey: .parentCurriculumFingerprint
        )
    }
}

struct CloudKitChatContextPayload: Codable, Sendable {
    let key: String
    let sourceIDs: [String]
    let sourceIdentities: [CloudKitSourceIdentityPayload]

    init(
        key: String,
        sourceIDs: [String],
        sourceIdentities: [CloudKitSourceIdentityPayload] = []
    ) {
        self.key = key
        self.sourceIDs = sourceIDs
        self.sourceIdentities = sourceIdentities
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case sourceIDs
        case sourceIdentities
    }

    init(
        from decoder: Decoder
    ) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        sourceIDs = try container.decode([String].self, forKey: .sourceIDs)
        sourceIdentities = try container.decodeIfPresent([CloudKitSourceIdentityPayload].self, forKey: .sourceIdentities) ?? []
    }
}

struct CloudKitReviewExchangePayload: Codable, Sendable {
    let id: String
    let sessionID: String
    let sequenceNumber: Int
    let question: String
    let userAnswer: String?
    let evaluation: String?
    let score: Double?
    let sourceRefs: [String]
    let knowledgeNote: String?
    let answeredAt: Date?
    /// The passage the message was sent with. Optional so a payload written by
    /// a pre-v84 client — which has no such key — still decodes, as nil rather
    /// than as a decoding failure that would strand the whole session.
    let contextContent: String?
    /// Memory review grading (schema 89): the ideas that came back, encoded
    /// as `[MemoryIdeaCoverage]` JSON, the question's verdict, its operation,
    /// and the learner's steer. All optional so a pre-v89 payload decodes.
    let ideaCoverage: String?
    let questionVerdict: String?
    let operation: String?
    let steer: String?
    /// The learner's thumb on one of this exchange's tutor turns (schema 93):
    /// `liked`/`disliked`, the reason they typed, which field of the exchange
    /// they rated (`question` or `evaluation`), and when. All optional so a
    /// pre-v93 payload decodes, and so a client that cannot carry them never
    /// blanks a rating the other device made.
    let rating: String?
    let ratingReason: String?
    let ratingField: String?
    let ratedAt: Date?

    init(
        id: String,
        sessionID: String,
        sequenceNumber: Int,
        question: String,
        userAnswer: String?,
        evaluation: String?,
        score: Double?,
        sourceRefs: [String],
        knowledgeNote: String?,
        answeredAt: Date?,
        contextContent: String? = nil,
        ideaCoverage: String? = nil,
        questionVerdict: String? = nil,
        operation: String? = nil,
        steer: String? = nil,
        rating: String? = nil,
        ratingReason: String? = nil,
        ratingField: String? = nil,
        ratedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.question = question
        self.userAnswer = userAnswer
        self.evaluation = evaluation
        self.score = score
        self.sourceRefs = sourceRefs
        self.knowledgeNote = knowledgeNote
        self.answeredAt = answeredAt
        self.contextContent = contextContent
        self.ideaCoverage = ideaCoverage
        self.questionVerdict = questionVerdict
        self.operation = operation
        self.steer = steer
        self.rating = rating
        self.ratingReason = ratingReason
        self.ratingField = ratingField
        self.ratedAt = ratedAt
    }
}

/// One doc passage a chat was opened on, carried inside the session's own
/// CloudKit record rather than as a record type of its own.
///
/// A link cannot outlive the chat it describes, and the session already syncs,
/// so nesting it here buys the whole relationship with no new record type and
/// so no CloudKit schema deploy — the same shape `exchanges` and
/// `sourceIdentities` already use.
struct CloudKitArtifactChatLinkPayload: Codable, Sendable {
    let id: String
    let artifactID: String
    let anchorRevision: String
    let anchorStart: Int
    let anchorEnd: Int
    let anchorQuote: String
    let sectionTitle: String
    let createdAt: Date
}

struct CloudKitReviewSessionPayload: Codable, Sendable {
    let id: String
    let topic: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let overallScore: Double?
    let summary: String?
    let sourceIDs: [String]
    let cardIDs: [String]
    let exchangeCount: Int
    let modelProvider: String?
    let modelID: String?
    /// The effort and speed the chat's last reply was asked for (schema 149),
    /// as `AIEffort` and `AISpeed` raw values; nil is the model's default
    /// effort and standard speed. A client from before them sends neither
    /// key, and `modelTuningFieldIsPresent` false keeps the local values;
    /// a current client always sends both, null included, so a pick put
    /// back to the default reaches the other Mac.
    let modelEffort: String?
    let modelSpeed: String?
    let modelTuningFieldIsPresent: Bool
    let goalID: String?
    /// Older clients omitted nil optional fields entirely. Preserve an existing
    /// Notebook relationship for those payloads, while letting current clients
    /// send an explicit JSON null to clear it intentionally.
    let goalIDFieldIsPresent: Bool
    let exchanges: [CloudKitReviewExchangePayload]
    let sourceIdentities: [CloudKitSourceIdentityPayload]
    /// The doc passages this chat was opened on. nil when the payload came from
    /// a client that predates them, which means "no opinion" and leaves the
    /// local links alone; an explicit empty array is a client saying the chat
    /// genuinely stands on no passage any more.
    let docLinks: [CloudKitArtifactChatLinkPayload]?
    /// `ReviewSessionKind`, and a memory review's tutor briefing (schema 89).
    /// nil from an older client means "no opinion" and keeps the local value.
    let kind: String?
    let briefing: String?
    /// The team this transcript snapshot belongs to (schema 96); nil for a
    /// learner's own chat. On the Mac the zone a record arrives from decides.
    let teamID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case topic
        case startedAt
        case endedAt
        case status
        case overallScore
        case summary
        case sourceIDs
        case cardIDs
        case exchangeCount
        case modelProvider
        case modelID
        case modelEffort
        case modelSpeed
        case goalID
        case exchanges
        case sourceIdentities
        case docLinks
        case kind
        case briefing
        case teamID
    }

    init(
        id: String,
        topic: String,
        startedAt: Date,
        endedAt: Date?,
        status: String,
        overallScore: Double?,
        summary: String?,
        sourceIDs: [String],
        cardIDs: [String],
        exchangeCount: Int,
        modelProvider: String? = nil,
        modelID: String? = nil,
        modelEffort: String? = nil,
        modelSpeed: String? = nil,
        goalID: String? = nil,
        exchanges: [CloudKitReviewExchangePayload],
        sourceIdentities: [CloudKitSourceIdentityPayload] = [],
        docLinks: [CloudKitArtifactChatLinkPayload]? = nil,
        kind: String? = nil,
        briefing: String? = nil,
        teamID: String? = nil
    ) {
        self.id = id
        self.topic = topic
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.overallScore = overallScore
        self.summary = summary
        self.sourceIDs = sourceIDs
        self.cardIDs = cardIDs
        self.exchangeCount = exchangeCount
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.modelEffort = modelEffort
        self.modelSpeed = modelSpeed
        self.modelTuningFieldIsPresent = true
        self.goalID = goalID
        self.goalIDFieldIsPresent = true
        self.exchanges = exchanges
        self.sourceIdentities = sourceIdentities
        self.docLinks = docLinks
        self.kind = kind
        self.briefing = briefing
        self.teamID = teamID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        topic = try container.decode(String.self, forKey: .topic)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try container.decode(String.self, forKey: .status)
        overallScore = try container.decodeIfPresent(Double.self, forKey: .overallScore)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        sourceIDs = try container.decode([String].self, forKey: .sourceIDs)
        cardIDs = try container.decode([String].self, forKey: .cardIDs)
        exchangeCount = try container.decode(Int.self, forKey: .exchangeCount)
        modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        modelTuningFieldIsPresent = container.contains(.modelEffort)
        modelEffort = try container.decodeIfPresent(String.self, forKey: .modelEffort)
        modelSpeed = try container.decodeIfPresent(String.self, forKey: .modelSpeed)
        goalIDFieldIsPresent = container.contains(.goalID)
        goalID = try container.decodeIfPresent(String.self, forKey: .goalID)
        exchanges = try container.decodeIfPresent([CloudKitReviewExchangePayload].self, forKey: .exchanges) ?? []
        sourceIdentities = try container.decodeIfPresent([CloudKitSourceIdentityPayload].self, forKey: .sourceIdentities) ?? []
        docLinks = try container.decodeIfPresent([CloudKitArtifactChatLinkPayload].self, forKey: .docLinks)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        briefing = try container.decodeIfPresent(String.self, forKey: .briefing)
        teamID = try container.decodeIfPresent(String.self, forKey: .teamID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(topic, forKey: .topic)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(overallScore, forKey: .overallScore)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(sourceIDs, forKey: .sourceIDs)
        try container.encode(cardIDs, forKey: .cardIDs)
        try container.encode(exchangeCount, forKey: .exchangeCount)
        try container.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        if modelTuningFieldIsPresent {
            // An explicit null tells the receiver "the default", where a
            // missing key would read as a client with no opinion.
            if let modelEffort {
                try container.encode(modelEffort, forKey: .modelEffort)
            } else {
                try container.encodeNil(forKey: .modelEffort)
            }
            if let modelSpeed {
                try container.encode(modelSpeed, forKey: .modelSpeed)
            } else {
                try container.encodeNil(forKey: .modelSpeed)
            }
        }
        if goalIDFieldIsPresent {
            if let goalID {
                try container.encode(goalID, forKey: .goalID)
            } else {
                try container.encodeNil(forKey: .goalID)
            }
        }
        try container.encode(exchanges, forKey: .exchanges)
        try container.encode(sourceIdentities, forKey: .sourceIdentities)
        try container.encodeIfPresent(docLinks, forKey: .docLinks)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(briefing, forKey: .briefing)
        try container.encodeIfPresent(teamID, forKey: .teamID)
    }
}

struct CloudKitLearningGoalPayload: Codable, Sendable {
    let goal: LearningGoalRecord
    let sourceIdentities: [CloudKitSourceIdentityPayload]
    /// nil when decoding a payload from an older device (preserve local links);
    /// an explicit empty array intentionally clears all course subscriptions.
    let linkedCourseIDs: [String]?

    init(
        goal: LearningGoalRecord,
        sourceIdentities: [CloudKitSourceIdentityPayload] = [],
        linkedCourseIDs: [String]? = nil
    ) {
        self.goal = goal
        self.sourceIdentities = sourceIdentities
        self.linkedCourseIDs = linkedCourseIDs
    }

    private enum CodingKeys: String, CodingKey {
        case goal
        case sourceIdentities
        case linkedCourseIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decode(LearningGoalRecord.self, forKey: .goal)
        sourceIdentities = try container.decodeIfPresent([CloudKitSourceIdentityPayload].self, forKey: .sourceIdentities) ?? []
        linkedCourseIDs = try container.decodeIfPresent([String].self, forKey: .linkedCourseIDs)
    }
}

struct CloudKitArtifactPayload: Codable, Sendable {
    let artifact: ArtifactRecord
    let bodyRevision: String?
    let bodyByteCount: Int?
    let bodyFormatVersion: Int?
    /// Decode-only compatibility with builds that embedded Markdown in the
    /// record envelope. New saves always leave this nil.
    let markdown: String?
    /// An animation's walkthrough (schema 124), the way a source's rides the
    /// Source payload: `decodeIfPresent`, so an older client leaves the local
    /// row alone and a newer one applies it.
    let walkthrough: PaperWalkthrough?

    init(
        artifact: ArtifactRecord,
        bodyRevision: String? = nil,
        bodyByteCount: Int? = nil,
        bodyFormatVersion: Int? = nil,
        markdown: String? = nil,
        walkthrough: PaperWalkthrough? = nil
    ) {
        self.artifact = artifact
        self.bodyRevision = bodyRevision
        self.bodyByteCount = bodyByteCount
        self.bodyFormatVersion = bodyFormatVersion
        self.markdown = markdown
        self.walkthrough = walkthrough
    }

    // A `lesson` key rode this payload for one unreleased day (schema 130);
    // a payload carrying it decodes past it.
    private enum CodingKeys: String, CodingKey {
        case artifact
        case bodyRevision
        case bodyByteCount
        case bodyFormatVersion
        case markdown
        case walkthrough
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifact = try container.decode(ArtifactRecord.self, forKey: .artifact)
        bodyRevision = try container.decodeIfPresent(String.self, forKey: .bodyRevision)
        bodyByteCount = try container.decodeIfPresent(Int.self, forKey: .bodyByteCount)
        bodyFormatVersion = try container.decodeIfPresent(Int.self, forKey: .bodyFormatVersion)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        walkthrough = try container.decodeIfPresent(PaperWalkthrough.self, forKey: .walkthrough)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artifact, forKey: .artifact)
        try container.encodeIfPresent(bodyRevision, forKey: .bodyRevision)
        try container.encodeIfPresent(bodyByteCount, forKey: .bodyByteCount)
        try container.encodeIfPresent(bodyFormatVersion, forKey: .bodyFormatVersion)
        try container.encodeIfPresent(markdown, forKey: .markdown)
        try container.encodeIfPresent(walkthrough, forKey: .walkthrough)
    }
}

/// A shared Schedule placement syncs as its own top-level record (it can't nest under
/// a single goal because it's shared across goals). Carries the placement, its goal
/// memberships, and the source identity for cross-device source-ID remapping.
struct CloudKitScheduledSourcePayload: Codable, Sendable {
    let placement: ScheduledSource
    let goalIDs: [String]
    let sourceIdentity: CloudKitSourceIdentityPayload?
    let activityDays: [SourceActivityDay]
    let isAutomatic: Bool

    init(
        placement: ScheduledSource,
        goalIDs: [String] = [],
        sourceIdentity: CloudKitSourceIdentityPayload? = nil,
        activityDays: [SourceActivityDay] = [],
        isAutomatic: Bool = false
    ) {
        self.placement = placement
        self.goalIDs = goalIDs
        self.sourceIdentity = sourceIdentity
        self.activityDays = activityDays
        self.isAutomatic = isAutomatic
    }

    private enum CodingKeys: String, CodingKey {
        case placement
        case goalIDs
        case sourceIdentity
        case activityDays
        case isAutomatic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placement = try container.decode(ScheduledSource.self, forKey: .placement)
        goalIDs = try container.decodeIfPresent([String].self, forKey: .goalIDs) ?? []
        sourceIdentity = try container.decodeIfPresent(CloudKitSourceIdentityPayload.self, forKey: .sourceIdentity)
        activityDays = try container.decodeIfPresent([SourceActivityDay].self, forKey: .activityDays) ?? []
        isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }
}

/// A recurring scheduled task and the receipts of its recent runs.
///
/// Receipts travel *inside* the task rather than as their own record type: a
/// run is meaningless without its task, and a second Mac that showed "never
/// run" for a task it had simply not personally executed would read as a broken
/// feature rather than as device-local history. The list is capped at
/// `ScheduledTask.retainedRunCount` so a long-lived daily task cannot grow one
/// record without bound.
struct CloudKitScheduledTaskPayload: Codable, Sendable {
    let task: ScheduledTask
    let runs: [ScheduledTaskRun]

    init(task: ScheduledTask, runs: [ScheduledTaskRun] = []) {
        self.task = task
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case task
        case runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(ScheduledTask.self, forKey: .task)
        runs = try container.decodeIfPresent([ScheduledTaskRun].self, forKey: .runs) ?? []
    }
}

/// A paper spotted on a video slide or in meeting material, synced so a decision
/// made on one Mac (imported, dismissed) is not re-offered on the other.
///
/// The candidate points at two sources — the source it was read from, and the paper
/// created when it was imported — and both must survive the trip. Source IDs are
/// per-device, so each foreign key travels with its own identity payload and is
/// remapped on arrival; a candidate that landed with a stripped `importedSourceID`
/// would read as un-imported and be offered a second time.
struct CloudKitVideoCitedPaperPayload: Codable, Sendable {
    let paper: VideoCitedPaper
    /// Identity of the evidence source, for remapping `paper.sourceID`.
    let sourceIdentity: CloudKitSourceIdentityPayload?
    /// Identity of the imported paper source, for remapping `paper.importedSourceID`.
    let importedSourceIdentity: CloudKitSourceIdentityPayload?

    init(
        paper: VideoCitedPaper,
        sourceIdentity: CloudKitSourceIdentityPayload? = nil,
        importedSourceIdentity: CloudKitSourceIdentityPayload? = nil
    ) {
        self.paper = paper
        self.sourceIdentity = sourceIdentity
        self.importedSourceIdentity = importedSourceIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case paper
        case sourceIdentity
        case importedSourceIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paper = try container.decode(VideoCitedPaper.self, forKey: .paper)
        sourceIdentity = try container.decodeIfPresent(CloudKitSourceIdentityPayload.self, forKey: .sourceIdentity)
        importedSourceIdentity = try container.decodeIfPresent(
            CloudKitSourceIdentityPayload.self,
            forKey: .importedSourceIdentity
        )
    }
}

// CloudKitAIUsageEventPayload lives in AIUsageReporting.swift so the mobile
// targets encode the exact same payload shape when authoring usage records.

enum CloudKitRecordMapper {
    static let contextLogicalKey = "current"
    static let zoneID = CKRecordZone.ID(zoneName: "Knowledge")

    /// CloudKit does not guarantee that records from one fetch are delivered in
    /// dependency order. Course lecture items have SQLite foreign keys to their
    /// source records, so sources must be installed before courses that link to
    /// them. The original order is retained within each priority bucket.
    static func inboundApplicationPriority(for record: CKRecord) -> Int {
        switch CloudKitSyncEntity.from(recordType: record.recordType) {
        case .source:
            return 0
        case .course, .memoryAttempt, .sourceHighlight, .notebookTask:
            return 2
        default:
            return 1
        }
    }

    /// Materialize a Book record's bounded cover asset at its portable path.
    /// This is deliberately eager: the operation runs on the CloudKit actor,
    /// never in a list row, and gives a Mac the same cover fallback as iPhone.
    @discardableResult
    private static func materializeInboundBookCoverIfNeeded(
        payload: CloudKitBookPayload,
        record: CKRecord,
        sourceContentRoot: URL?
    ) -> String? {
        guard let asset = record[.bookCoverAsset] as? CKAsset,
              let assetURL = asset.fileURL,
              FileManager.default.isReadableFile(atPath: assetURL.path),
              let imageSource = CGImageSourceCreateWithURL(assetURL as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            return nil
        }

        let root = (sourceContentRoot
            ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .standardizedFileURL
        let proposedRelative = payload.coverPath.map(StorageService.relativeSourcePath)
        let safeRelative: String
        if let proposedRelative,
           !proposedRelative.isEmpty,
           !proposedRelative.hasPrefix("/"),
           ["jpg", "jpeg", "png"].contains(URL(fileURLWithPath: proposedRelative).pathExtension.lowercased()) {
            safeRelative = proposedRelative
        } else {
            // Book ids can be user-visible titles. Keep them out of file paths.
            let digest = SHA256.hash(data: Data(payload.id.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            safeRelative = "Books/.synced-covers/\(digest)/cover.jpg"
        }
        let destination = root.appendingPathComponent(safeRelative).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }

        let fileManager = FileManager.default
        if fileManager.isReadableFile(atPath: destination.path),
           let existing = CGImageSourceCreateWithURL(destination as CFURL, nil),
           CGImageSourceGetCount(existing) > 0 {
            return safeRelative
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).cover", isDirectory: false)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: assetURL, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            return safeRelative
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "CloudKitSync"
            ).warning(
                "Inbound book cover could not be materialized for \(payload.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func coursePayload(from record: CKRecord) throws -> CloudKitCoursePayload? {
        guard CloudKitSyncEntity.from(recordType: record.recordType) == .course else {
            return nil
        }
        guard let data = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        return try JSONDecoder().decode(CloudKitCoursePayload.self, from: data)
    }

    static func recordName(for entity: CloudKitSyncEntity, logicalKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(entity.rawValue):\(logicalKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The record's CloudKit address at its home. The name is a pure function
    /// of entity and logical key; the home is what places it in a zone.
    static func recordID(
        for entity: CloudKitSyncEntity,
        logicalKey: String,
        in home: CloudKitZoneHome = .knowledge
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: entity, logicalKey: logicalKey), zoneID: home.zoneID)
    }

    private struct WebPDFImportIdentity {
        let fileName: String
        let fileKind: String
        let relativePath: String
        let durableRelativePath: String
    }

    /// Web Studio cannot write into the app's iCloud Documents container. It
    /// therefore publishes the original as a Source CKAsset and gives the source
    /// a stable `Web Imports/<UUID>/<filename>` identity. Requiring all three
    /// pieces prevents this exception from turning the ordinary Mac-authored
    /// `sourcePDFAsset` compatibility feed into a second Mac ingestion rail.
    private static func webPDFImportIdentity(
        article: StudioArticle,
        declaredFileName: String,
        declaredFileKind: String? = nil
    ) throws -> WebPDFImportIdentity {
        let components = article.url.split(separator: "/", omittingEmptySubsequences: true)
        let markerIndex = components.indices.last(where: { components[$0] == "Web Imports" })
        let extensionKind = URL(fileURLWithPath: declaredFileName).pathExtension.lowercased()
        let fileKind = declaredFileKind?.lowercased() ?? extensionKind
        let isPaperPDF = article.sourceType == .paper && fileKind == "pdf"
        let isBookFile = article.sourceType == .book && (fileKind == "pdf" || fileKind == "epub")
        guard isPaperPDF || isBookFile,
              !article.url.contains("://"),
              let markerIndex,
              markerIndex == components.count - 3,
              UUID(uuidString: String(components[markerIndex + 1])) != nil,
              String(components[markerIndex + 2]) == declaredFileName,
              !declaredFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF identity is invalid for \(article.id)."
            )
        }

        var baseName = declaredFileName
        let suffix = "." + fileKind
        if baseName.lowercased().hasSuffix(suffix) {
            baseName.removeLast(suffix.count)
        }
        let safeBaseName = baseName.unicodeScalars.prefix(48).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 0x2F // /
                || scalar.value == 0x5C // \
                || scalar.value == 0x3A // :
            {
                return "_"
            }
            return String(scalar)
        }.joined().trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )
        let fallbackName = article.sourceType == .book ? "Imported Book" : "Imported Paper"
        let destinationName = (safeBaseName.isEmpty ? fallbackName : safeBaseName) + suffix
        let importID = components[markerIndex + 1]
        let collection = article.sourceType == .book ? "Books" : "Papers"
        let relativePath = "\(collection)/Web Imports/\(importID)/\(destinationName)"
        let durableRelativePath = "\(importID)/\(destinationName)"
        return WebPDFImportIdentity(
            fileName: declaredFileName,
            fileKind: fileKind,
            relativePath: relativePath,
            durableRelativePath: durableRelativePath
        )
    }

    /// Preserve the browser marker on a Mac republish only while the source still
    /// points at the canonical materialized web file. If the user later attaches
    /// a different PDF, that ordinary Mac-owned file keeps the historic one-way
    /// Mac -> iOS asset behavior.
    private static func outboundWebPDFImportIdentity(
        for article: StudioArticle
    ) -> WebPDFImportIdentity? {
        guard let localFilePath = article.localFilePath,
              !localFilePath.contains("://") else { return nil }
        let components = article.url.split(separator: "/", omittingEmptySubsequences: true)
        guard let markerIndex = components.indices.last(where: {
            components[$0] == "Web Imports"
        }), markerIndex == components.count - 3 else { return nil }
        let fileName = String(components[markerIndex + 2])
        guard let identity = try? webPDFImportIdentity(
            article: article,
            declaredFileName: fileName,
            declaredFileKind: URL(fileURLWithPath: fileName).pathExtension
        ) else { return nil }
        let relativeLocalPath = StorageService.relativeSourcePath(localFilePath)
        guard relativeLocalPath == identity.relativePath
                || localFilePath.hasSuffix("/" + identity.relativePath)
                || localFilePath.hasSuffix(
                    "/.web-pdf-imports/" + identity.durableRelativePath
                ) else {
            return nil
        }
        return identity
    }

    private static let maxWebPDFAssetBytes: Int64 = 50 * 1024 * 1024

    /// Materialize the browser's temporary CKAsset into the durable source tree
    /// before SQLite receives the corresponding `localFilePath`. The sync engine
    /// actor calls this method off-main. A same-directory staging copy plus atomic
    /// replacement means a crash can leave an orphan staging file, but never a
    /// source row pointing at a partially copied PDF; replay is idempotent.
    private static func materializeInboundWebPDFIfNeeded(
        payload: CloudKitSourcePayload,
        record: CKRecord,
        sourceContentRoot: URL?,
        durableImportRoot: URL
    ) throws -> String? {
        guard let fileKind = payload.webFileKind?.lowercased(),
              fileKind == "pdf" || fileKind == "epub" else { return nil }
        guard let declaredFileName = payload.webFileName else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF is missing its filename for \(payload.article.id)."
            )
        }
        let identity = try webPDFImportIdentity(
            article: payload.article,
            declaredFileName: declaredFileName,
            declaredFileKind: fileKind
        )

        let root = (sourceContentRoot ?? URL(
            fileURLWithPath: StorageService.libraryRootPath,
            isDirectory: true
        )).standardizedFileURL
        let destination = root
            .appendingPathComponent(identity.relativePath, isDirectory: false)
            .standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF destination escaped the source root for \(payload.article.id)."
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path),
           canOpenWebImport(at: destination.path, fileKind: identity.fileKind) {
            return destination.path
        }

        let durableRoot = durableImportRoot.standardizedFileURL
        let durableDestination = durableRoot
            .appendingPathComponent(identity.durableRelativePath, isDirectory: false)
            .standardizedFileURL
        guard durableDestination.path.hasPrefix(durableRoot.path + "/") else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF fallback escaped the durable import root for \(payload.article.id)."
            )
        }
        let hasDurableFallback = fileManager.fileExists(atPath: durableDestination.path)
            && canOpenWebImport(at: durableDestination.path, fileKind: identity.fileKind)

        guard let asset = record[.sourcePDFAsset] as? CKAsset,
              let assetURL = asset.fileURL else {
            if hasDurableFallback { return durableDestination.path }
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF is missing its asset for \(payload.article.id)."
            )
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: assetURL.path)
        } catch {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "CloudKit web PDF asset is temporarily unavailable for \(payload.article.id): "
                    + error.localizedDescription
            )
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0, byteCount <= maxWebPDFAssetBytes else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF has an invalid size for \(payload.article.id)."
            )
        }
        guard fileManager.isReadableFile(atPath: assetURL.path) else {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "CloudKit web PDF asset is temporarily unreadable for \(payload.article.id)."
            )
        }
        guard canOpenWebImport(at: assetURL.path, fileKind: identity.fileKind) else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "CloudKit web PDF is unreadable for \(payload.article.id)."
            )
        }

        do {
            return try installWebPDFAsset(
                from: assetURL,
                to: destination,
                fileKind: identity.fileKind
            )
        } catch {
            // A temporarily unavailable iCloud container must not consume the
            // CloudKit change token and strand the only downloadable copy. Keep
            // the asset beside knowledge.db instead; the queued paper pipeline
            // can consume that stable local file immediately, and a later replay
            // may promote it to the normal Papers tree.
            do {
                if hasDurableFallback { return durableDestination.path }
                return try installWebPDFAsset(
                    from: assetURL,
                    to: durableDestination,
                    fileKind: identity.fileKind
                )
            } catch let fallbackError {
                if let storeError = fallbackError as? KnowledgeStoreError,
                   case .permanentInboundWebPDF = storeError {
                    throw storeError
                }
                throw KnowledgeStoreError.transientInboundWebPDF(
                    "CloudKit web PDF could not be installed for \(payload.article.id): "
                        + fallbackError.localizedDescription
                )
            }
        }
    }

    private static func installWebPDFAsset(
        from assetURL: URL,
        to destination: URL,
        fileKind: String
    ) throws -> String {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "The CloudKit web PDF destination is temporarily unavailable: "
                    + error.localizedDescription
            )
        }
        let staging = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).importing",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.copyItem(at: assetURL, to: staging)
        } catch {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "The CloudKit web PDF asset could not be copied: " + error.localizedDescription
            )
        }
        guard canOpenWebImport(at: staging.path, fileKind: fileKind) else {
            throw KnowledgeStoreError.permanentInboundWebPDF(
                "The staged CloudKit web PDF is unreadable."
            )
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "The CloudKit web PDF could not be installed: " + error.localizedDescription
            )
        }
        guard canOpenWebImport(at: destination.path, fileKind: fileKind) else {
            throw KnowledgeStoreError.transientInboundWebPDF(
                "The installed CloudKit web PDF is temporarily unreadable."
            )
        }
        return destination.path
    }

    private static func pathLooksLikeArchivedArticle(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let lower = normalized.lowercased()
        return lower.hasSuffix(".html")
            && (lower.hasPrefix("articles/") || lower.contains("/articles/"))
    }

    /// Install the self-contained HTML carried by an archived article's Source
    /// record. The original import may contain a sender-specific absolute path;
    /// the receiver always stores a deterministic, portable relative path.
    ///
    /// Best-effort like ordinary inbound source PDFs: the canonical extracted
    /// text remains readable when the rich document is absent or temporarily
    /// unavailable. File reads and writes run on the sync engine actor.
    private static func materializeInboundArchivedArticleIfNeeded(
        article: StudioArticle,
        record: CKRecord,
        sourceContentRoot: URL?
    ) -> String? {
        guard let stored = article.localFilePath,
              pathLooksLikeArchivedArticle(stored),
              !article.id.isEmpty,
              article.id != ".",
              article.id != "..",
              !article.id.contains("/"),
              !article.id.contains(":"),
              let asset = record[.sourceReaderHTMLAsset] as? CKAsset,
              let assetURL = asset.fileURL,
              FileManager.default.isReadableFile(atPath: assetURL.path) else { return nil }

        let relativePath = "Articles/\(article.id)/article.html"
        let root = (sourceContentRoot
            ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .standardizedFileURL
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }

        let fileManager = FileManager.default
        if fileManager.isReadableFile(atPath: destination.path),
           let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber,
           size.intValue > 0 {
            return relativePath
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: assetURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0, byteCount <= EPUBParser.maxReaderDocumentBytes else { return nil }
            let html = try String(contentsOf: assetURL, encoding: .utf8)
            let safeHTML = EPUBParser.readerDocument(
                fromHTML: html,
                chapterPath: destination.path
            ).html
            guard !safeHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(safeHTML.utf8).write(to: destination, options: .atomic)
            return relativePath
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "CloudKitSync"
            ).warning(
                "Inbound article archive could not be materialized for \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Install the icon carried by a meeting's Source record.
    ///
    /// The stored path is never rewritten and never trusted. It is already
    /// correct — `MeetingIconService.relativePath` derives it from the source id,
    /// so both Macs compute the same one — but an `artwork_url` is ordinary
    /// synced text, and text off the wire does not get to choose where this
    /// writes. The arriving path is checked against the two this app can
    /// possibly have written for this source, and anything else is dropped.
    ///
    /// Best-effort like the inbound PDF: a failure leaves the meeting on its
    /// fallback glyph, which is where it already was.
    ///
    /// Stats and writes on the sync engine's background path, never a render one.
    @discardableResult
    private static func materializeInboundMeetingIconIfNeeded(
        article: StudioArticle,
        record: CKRecord,
        sourceContentRoot: URL?
    ) -> Bool {
        guard article.sourceType == .meeting,
              let artwork = article.artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artwork.isEmpty,
              let asset = record[.meetingIconAsset] as? CKAsset,
              let assetURL = asset.fileURL,
              FileManager.default.isReadableFile(atPath: assetURL.path) else { return false }

        // The only two relative paths this app ever writes a meeting icon to.
        let permitted = [
            MeetingIconService.relativePath(sourceID: article.id, drawn: false),
            MeetingIconService.relativePath(sourceID: article.id, drawn: true),
        ]
        let relativePath = StorageService.relativeSourcePath(artwork)
        guard permitted.contains(relativePath) else { return false }

        let root = (sourceContentRoot
            ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .standardizedFileURL
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return false }

        let fileManager = FileManager.default
        if fileManager.isReadableFile(atPath: destination.path),
           let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber,
           size.intValue > 0 {
            return false
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: assetURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0, byteCount <= maxMeetingIconAssetBytes else { return false }
            // An icon is an image or it is nothing. A row that drew whatever
            // arrived would turn a malformed asset into a broken thumbnail.
            guard let imageSource = CGImageSourceCreateWithURL(assetURL as CFURL, nil),
                  CGImageSourceGetCount(imageSource) > 0 else { return false }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).icon", isDirectory: false)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: assetURL, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            MeetingIconService.noteStoredIconChanged(absolutePath: destination.path)
            return true
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "CloudKitSync"
            ).warning(
                "Inbound meeting icon could not be materialized for \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Write an inbound paper or chapter PDF to this device's content root when
    /// the file is not already here.
    ///
    /// This closes the gap that CloudDocs used to cover. `sourcePDFAsset` has
    /// always been published for every paper and PDF-backed chapter, but only iOS
    /// and browser imports ever consumed it — a receiving Mac was expected to get
    /// the file through the ubiquity container instead, and when that lagged the
    /// paper sat there reporting "PDF needed" with its own bytes present in the
    /// very record being applied. Content is local now, so this asset is the
    /// transport, and a Mac consumes it exactly like a phone does.
    ///
    /// The stored path is not rewritten: it is already the right relative path,
    /// only the bytes were missing. And a file found under *any* known root —
    /// including the numbered iCloud forks that still hold most of this library —
    /// counts as present, so this never duplicates gigabytes that are merely
    /// sitting somewhere older.
    ///
    /// Best-effort by design. A failure here leaves the source exactly as it
    /// arrived, which is the pre-existing needs-a-PDF flow, rather than throwing
    /// and stranding an otherwise-good record.
    ///
    /// Stats and copies on the sync engine's background path — never a render path.
    @discardableResult
    private static func materializeInboundSourcePDFIfNeeded(
        article: StudioArticle,
        record: CKRecord,
        sourceContentRoot: URL?
    ) -> Bool {
        // Every type whose original document ships as `sourcePDFAsset` — keep this
        // in step with `documentPDFPath` on the outbound side, or a type uploads
        // its PDF and then refuses to install the one it is sent.
        guard article.sourceType == .paper
            || article.sourceType == .book
            || article.sourceType == .course else { return false }
        return installRecordedSourcePDFAsset(
            from: record,
            storedPath: article.localFilePath,
            sourceContentRoot: sourceContentRoot,
            logicalKey: article.id
        ) != nil
    }

    /// Install `sourcePDFAsset` at the path a source already has on record, and
    /// answer where it landed.
    ///
    /// Shared by the inbound apply above and by the sync engine's direct
    /// recovery read, which fetches this one field for sources whose recorded
    /// document is on no disk this Mac can see. Both want the identical rules:
    /// never overwrite bytes that are already somewhere local, never re-root an
    /// absolute path from a layout this device does not know, and never write
    /// outside the content root.
    static func installRecordedSourcePDFAsset(
        from record: CKRecord,
        storedPath: String?,
        sourceContentRoot: URL?,
        logicalKey: String
    ) -> String? {
        guard let stored = storedPath,
              !stored.isEmpty,
              !stored.contains("://"),
              stored.lowercased().hasSuffix(".pdf") else { return nil }
        // Already on this Mac somewhere — the local root, the container, a fork.
        guard StorageService.locateSourceFile(stored) == nil else { return nil }

        let relative = StorageService.relativeSourcePath(stored)
        // An absolute path that reduces to nothing relative cannot be re-rooted
        // here; it belongs to a layout this device knows nothing about.
        guard !relative.hasPrefix("/"), !relative.isEmpty else { return nil }

        guard let asset = record[.sourcePDFAsset] as? CKAsset,
              let assetURL = asset.fileURL,
              FileManager.default.isReadableFile(atPath: assetURL.path) else { return nil }

        let root = (sourceContentRoot
            ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .standardizedFileURL
        let destination = root.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }

        do {
            return try installWebPDFAsset(from: assetURL, to: destination, fileKind: "pdf")
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "CloudKitSync"
            ).warning(
                "Inbound PDF could not be materialized for \(logicalKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The digest a restored document would produce on its next outbound save.
    ///
    /// A digest asserts what the server already holds. Bytes that just came
    /// *from* the server are exactly that, so recording this after a recovery
    /// install keeps the next unrelated republish from re-uploading gigabytes of
    /// PDFs CloudKit is already storing — the path and mtime changed, the
    /// content did not.
    static func recoveredSourcePDFAssetDigest(atPath path: String) -> String {
        fileDigest(path, variant: "pdf")
    }

    /// Install an EPUB chapter's `sourceReaderHTMLAsset` at the path the chapter
    /// already has on record, and answer where it landed.
    ///
    /// The EPUB twin of `installRecordedSourcePDFAsset`. A PDF-split book reaches
    /// a second Mac through its chapter PDFs, but an EPUB book had no transport
    /// at all: its chapters are XHTML beside their images, only the phone ever
    /// consumed the reader document the owning Mac publishes, and a receiving
    /// Mac was left with the cover and the stripped text — "We Are Electric"
    /// and five other books read as plain text on the Mac that did not import
    /// them. The reader document is that chapter's own markup with every image
    /// inlined, so written at the chapter's path it is a complete chapter file.
    ///
    /// Written as HTML under a `<!DOCTYPE html>` line, which is what makes
    /// `EPUBKitReaderSupport.normalizedXHTMLContent` load an `.xhtml` path as
    /// HTML: the document is sanitized HTML, not well-formed XML, and WebKit's
    /// strict XHTML parser would refuse it.
    static func installRecordedBookChapterDocument(
        from record: CKRecord,
        storedPath: String?,
        sourceContentRoot: URL?,
        logicalKey: String
    ) -> String? {
        guard let stored = storedPath,
              !stored.isEmpty,
              !stored.contains("://"),
              EPUBParser.isMarkupChapter(stored) else { return nil }
        // Already on this Mac somewhere — the local root, the container, a fork.
        guard StorageService.locateSourceFile(stored) == nil else { return nil }

        let relative = StorageService.relativeSourcePath(stored)
        guard !relative.hasPrefix("/"), !relative.isEmpty else { return nil }

        guard let asset = record[.sourceReaderHTMLAsset] as? CKAsset,
              let assetURL = asset.fileURL,
              FileManager.default.isReadableFile(atPath: assetURL.path) else { return nil }

        let root = (sourceContentRoot
            ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .standardizedFileURL
        let destination = root.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { return nil }

        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: assetURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0, byteCount <= EPUBParser.maxReaderDocumentBytes else { return nil }
            // Sanitized again on arrival: text off the wire does not get to
            // carry script into a local file the reader opens.
            let body = EPUBParser.readerDocument(
                fromHTML: try String(contentsOf: assetURL, encoding: .utf8),
                chapterPath: destination.path
            ).html
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let document = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>\n\(body)\n</body></html>\n"
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(document.utf8).write(to: destination, options: .atomic)
            return destination.path
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
                category: "CloudKitSync"
            ).warning(
                "Inbound book chapter could not be materialized for \(logicalKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// `recoveredSourcePDFAssetDigest` for a restored chapter document. Without
    /// it the next unrelated save would upload a reader document rebuilt from
    /// the one that just came down, in place of the owning Mac's.
    static func recoveredReaderDocumentAssetDigest(atPath path: String) -> String {
        fileDigest(path, variant: readerDocumentDigestVariant)
    }

    private static let readerDocumentDigestVariant = "reader-html-v2"

    /// Lightweight original-file validation performed on the sync actor before
    /// a queued source points at the copied bytes. PDFKit owns PDF validation;
    /// an EPUB is a ZIP container and is fully parsed later by the book importer.
    private static func canOpenWebImport(at path: String, fileKind: String) -> Bool {
        if fileKind == "pdf" { return SourceService.canOpenPDF(at: path) }
        guard fileKind == "epub",
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 4) else { return false }
        return signature == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// - Parameter deferContent: send the record's metadata now and leave its
    ///   assets for a later pass. A container migration re-queues the whole
    ///   library, and the library is mostly small records carrying multi-megabyte
    ///   content; shipping metadata first makes every device show the library in
    ///   minutes instead of waiting days for gigabytes to cross. The skipped
    ///   fields are left unstaged, so the record still reads as owing them and
    ///   the content pass re-attaches exactly what was held back.
    static func makeRecord(
        for change: CloudKitPendingChange,
        store: KnowledgeStore,
        deferContent: Bool = false
    ) throws -> CKRecord? {
        let metadata = try store.loadSyncMetadata(entity: change.entity, logicalKey: change.logicalKey)
        let recordID = CKRecord.ID(recordName: change.recordName, zoneID: change.home.zoneID)
        let record = metadata?.systemFieldsData.flatMap(decodeSystemFields) ?? CKRecord(recordType: change.entity.recordType, recordID: recordID)

        // Records are re-sent for all sorts of reasons that have nothing to do
        // with their attachments — a reading-position bump, a regenerated review
        // guide, a notebook membership change. Rebuilding the assets every time
        // re-uploaded every paper's full PDF on each of those saves, and CloudKit
        // keeps a cached copy of every upload, which is how ~600 papers turned
        // into 20k cached asset blobs. Only attach an asset whose content has
        // actually moved since the last acknowledged save; leaving the field
        // unset makes CloudKit keep the copy it already has.
        //
        // Unacknowledged is not the same as unsent, so a field the server may
        // still be owed is always re-attached rather than skipped. `stagedAsset`
        // is what keeps that retry from costing a second upload.
        let previousAssetDigests = try store.committedAssetDigests(recordName: change.recordName)
        var assetDigests: [String: String] = [:]
        var heldBackContent = false
        /// - Parameter deferrable: whether a content-deferring pass may hold
        ///   this field back. False for an asset that *is* the record's payload
        ///   rather than an attachment to it: a review session shipped as a
        ///   `payloadAsset` with the asset held back would arrive with no
        ///   payload at all and be refused by every receiver.
        func attachAsset(
            _ field: CKRecord.FieldKey,
            digest: String,
            deferrable: Bool = true,
            build: (String) throws -> CKAsset?
        ) rethrows {
            guard previousAssetDigests[field] != digest else {
                assetDigests[field] = digest
                return
            }
            if deferContent && deferrable {
                // Staging nothing is the whole mechanism: with no digest for
                // this field the next save sees it as changed and uploads it.
                heldBackContent = true
                return
            }
            assetDigests[field] = digest
            record[field] = try stagedAsset(
                recordName: change.recordName,
                field: field,
                digest: digest,
                build: build
            )
        }
        defer {
            try? store.stageAssetDigests(assetDigests, recordName: change.recordName)
            if heldBackContent {
                try? store.markContentDeferred(recordName: change.recordName)
            }
        }

        switch change.entity {
        case .source:
            guard var article = try store.loadSourceForSync(change.logicalKey) else { return nil }
            let webPDFImport = outboundWebPDFImportIdentity(for: article)
            let content = article.content
            let paperPreparation = try store.loadPaperContentPreparation(change.logicalKey)
            let articlePreparation = try store.loadArticleContentPreparation(change.logicalKey)
            let podcastPreparation = try store.loadPodcastTranscriptPreparation(change.logicalKey)
            let listenableContent = try store.loadSourceListenableContent(change.logicalKey)
            let rawPreparation: String?
            switch article.sourceType {
            case .paper:
                rawPreparation = paperPreparation?.raw
            case .podcast:
                rawPreparation = podcastPreparation?.input
            default:
                rawPreparation = articlePreparation?.raw
            }
            let rawTTML = try store.loadPodcastRawTTML(change.logicalKey)
            let walkthrough = try store.loadPaperWalkthrough(change.logicalKey)
            article.content = nil
            article.podcastMatch = nil
            article.podcastMatchTrackId = nil
            // `loadSourceForSync` resolves portable database paths for local
            // readers. Never put that Mac-specific absolute path on the wire:
            // another Mac would canonicalize it back to the same relative path,
            // republish the apparent difference, then receive its own save and
            // repeat forever. CloudKit identity is the stored relative path.
            if let localFilePath = article.localFilePath {
                article.localFilePath = StorageService.relativeSourcePath(localFilePath)
            }
            // A team copy is everyone's; where one member got to in it is not.
            // Reading progress stays on the member's own device and never
            // travels in a team-homed record (see docs/teams-design.md).
            if change.home.isTeamZone {
                article.readAt = nil
                article.readingPositionPage = nil
                article.readingPositionLocator = nil
            }
            let payload = try JSONEncoder().encode(CloudKitSourcePayload(
                article: article,
                sourceIdentity: try store.sourceIdentities(for: [change.logicalKey]).first,
                visiblePodcastEpisodeOverride: try store.isPodcastEpisodeVisibleOverride(change.logicalKey),
                visibleYouTubeVideoOverride: try store.isYouTubeVideoVisibleOverride(change.logicalKey),
                sourceUnits: try store.loadSourceUnitsForSync(change.logicalKey),
                paperContentPreparation: paperPreparation?.metadata,
                articleContentPreparation: articlePreparation?.metadata,
                podcastTranscriptCleanup: podcastPreparation?.metadata,
                listenableContentMetadata: listenableContent?.metadata,
                sourceReviewGuide: try store.loadSourceReviewGuide(change.logicalKey),
                paperWalkthrough: walkthrough,
                paperFigures: try store.syncedPaperFigures(sourceID: change.logicalKey),
                webFileName: webPDFImport?.fileName,
                webFileKind: webPDFImport?.fileKind,
                reviewDepth: change.home.isTeamZone
                    ? nil
                    : try store.loadSourceReviewDepth(sourceID: change.logicalKey)?.rawValue
            ))
            record.encryptedValues[.payload] = payload as NSData
            try attachAsset(.sourceContentAsset, digest: textDigest(content)) { digest in
                try makeTextAsset(
                    for: content,
                    recordName: change.recordName,
                    suffix: "content",
                    fileExtension: "txt",
                    digest: digest
                )
            }
            try attachAsset(.sourceRawContentAsset, digest: textDigest(rawPreparation)) { digest in
                try makeTextAsset(
                    for: rawPreparation,
                    recordName: change.recordName,
                    suffix: "raw-content",
                    fileExtension: "txt",
                    digest: digest
                )
            }
            try attachAsset(
                .sourceListenableContentAsset,
                digest: textDigest(listenableContent?.text)
            ) { digest in
                try makeTextAsset(
                    for: listenableContent?.text,
                    recordName: change.recordName,
                    suffix: "listenable-content",
                    fileExtension: "txt",
                    digest: digest
                )
            }
            try attachAsset(.podcastRawTTMLAsset, digest: textDigest(rawTTML)) { digest in
                try makeTextAsset(
                    for: rawTTML,
                    recordName: change.recordName,
                    suffix: "raw-ttml",
                    fileExtension: "ttml",
                    digest: digest
                )
            }
            // A paper ships its original document, and so does a PDF-backed book
            // chapter: the chapter PDF is the only form in which its figures,
            // plates and layout can reach a device without the book files.
            //
            // Course material ships for a blunter reason: it has no other
            // transport. Its bytes used to travel through the ubiquity container
            // and nothing replaced that when content moved local, so a lecture
            // PDF added on one Mac simply never reached the other. All 104 in
            // this library are single PDFs averaging 2.6 MB — the same shape as
            // a paper, and the largest is 57 MB, well inside the asset cap.
            let expectsPDFAsset = article.sourceType == .paper
                || article.sourceType == .book
                || article.sourceType == .course
            let documentPDFPath = expectsPDFAsset ? article.resolvedPDFPath : nil
            // The thumbnail stays paper-only, and gating it on its own stat also
            // skips the PDFKit render for everything else, not just the upload.
            let thumbnailPDFPath = article.sourceType == .paper ? article.resolvedPDFPath : nil
            // EPUB chapters and archived articles have no portable original
            // document: their figures sit beside XHTML/HTML. Ship one sanitized,
            // self-contained reader document with those images inlined.
            let recordedReaderPath = article.localFilePath ?? article.url
            let expectsReaderDocument = documentPDFPath == nil
                && ((article.sourceType == .book && EPUBParser.isMarkupChapter(recordedReaderPath))
                    || pathLooksLikeArchivedArticle(recordedReaderPath))
            let resolvedReaderPath = expectsReaderDocument
                ? article.resolvedLocalPath.flatMap {
                    FileManager.default.isReadableFile(atPath: $0) ? $0 : nil
                }
                : nil
            let cachedArchivePath: String? = pathLooksLikeArchivedArticle(recordedReaderPath)
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    .map {
                        $0.appendingPathComponent(
                            "\(ForeverLMRuntimeIdentity.productFolderName)/ArticleArchives",
                            isDirectory: true
                        )
                            .appendingPathComponent(article.id, isDirectory: true)
                            .appendingPathComponent("article.html").path
                    }
                    .flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil }
                : nil
            let readerDocumentPath = resolvedReaderPath ?? cachedArchivePath
            // Web Studio already installed the authoritative asset on this
            // server record, potentially up to CloudKit's 50 MB asset limit. Leave
            // that field unchanged on the Mac's required metadata republish:
            // rebuilding would both duplicate the upload and clear web PDFs
            // above the ordinary 30 MB Mac -> iOS compatibility cap.
            if webPDFImport == nil {
                if let documentPDFPath {
                    attachAsset(
                        .sourcePDFAsset,
                        digest: fileDigest(documentPDFPath, variant: "pdf")
                    ) { digest in
                        makeSourcePDFAsset(
                            path: documentPDFPath,
                            recordName: change.recordName,
                            digest: digest
                        )
                    }
                } else if !expectsPDFAsset {
                    // A Mac that has received the source metadata but not its
                    // original document is not evidence that the server asset
                    // was deleted. Leaving this field untouched preserves the
                    // other Mac's PDF; assigning nil here used to erase it on
                    // any unrelated metadata republish, permanently stranding
                    // the receiving Mac in "PDF needed". Only a source that no
                    // longer has a PDF-carrying type may deliberately clear it.
                    attachAsset(.sourcePDFAsset, digest: absentAssetDigest) { _ in nil }
                }
            }
            attachAsset(
                .paperThumbnailAsset,
                digest: fileDigest(thumbnailPDFPath, variant: "thumbnail-v1")
            ) { digest in
                makePaperThumbnailAsset(for: article, recordName: change.recordName, digest: digest)
            }
            // A meeting icon has no other transport, for the same reason course
            // material had none: it used to travel through the ubiquity
            // container, and content moved local. The path kept syncing on its
            // own — it is an ordinary column — so the receiving Mac ended up
            // holding a path to a picture it had never been sent, and showing
            // the fallback glyph beside it forever.
            if let readableIconPath = readableMeetingIconPath(for: article) {
                attachAsset(
                    .meetingIconAsset,
                    digest: fileDigest(readableIconPath, variant: "meeting-icon-v1")
                ) { digest in
                    makeMeetingIconAsset(
                        absolutePath: readableIconPath,
                        recordName: change.recordName,
                        digest: digest
                    )
                }
            } else if article.sourceType == .meeting, !recordsLocalMeetingIcon(article) {
                // Only a meeting that genuinely has no icon of ours clears the
                // field. A Mac that holds the path but not the bytes — every Mac
                // that has not yet been sent them — must leave the server copy
                // alone, or its next unrelated metadata save erases the icon
                // every other device is showing. Same erasure `sourcePDFAsset`
                // and `bookCoverAsset` guard against above.
                //
                // Papers and podcasts do not clear it either, though they never
                // have one: this field is new, and a nil assigned to a field the
                // Production schema has not been given yet is a save the server
                // can refuse. Keeping every non-meeting record away from it is
                // what bounds that window to the type the feature is about.
                attachAsset(.meetingIconAsset, digest: absentAssetDigest) { _ in nil }
            }
            if expectsReaderDocument {
                // A receiving Mac may know the source before its rich bytes have
                // arrived. Leaving the field and digest untouched preserves the
                // server copy instead of clearing it during an unrelated save.
                if let readerDocumentPath {
                    attachAsset(
                        .sourceReaderHTMLAsset,
                        digest: fileDigest(readerDocumentPath, variant: readerDocumentDigestVariant)
                    ) { digest in
                        makeReaderHTMLAsset(
                            markupPath: readerDocumentPath,
                            recordName: change.recordName,
                            digest: digest
                        )
                    }
                }
            } else {
                attachAsset(.sourceReaderHTMLAsset, digest: absentAssetDigest) { _ in nil }
            }
            // The drawn pictures the walk's steps name live in this Mac's
            // image store, which nothing else syncs ("Generated chat
            // pictures" in docs/backend-storage-sync.md), so they ride beside
            // the walk to the other Macs, the phone and, in a team's zone, its
            // members. A picture this Mac lacks is left out and the rest still
            // travel; a Mac that holds none of them leaves the server's copy
            // alone. The field is cleared only once the walk names no picture
            // at all, and only by a Mac that sent one: a source that never had
            // any keeps away from a field the Production schema may lack.
            let walkPictureIDs = walkthrough?.drawnPictureIDs ?? []
            if !walkPictureIDs.isEmpty {
                let pictures = WalkthroughPicturePackage.contents(for: walkPictureIDs)
                if !pictures.isEmpty {
                    attachAsset(.walkthroughPicturesAsset, digest: pictures.digest) { digest in
                        makeWalkthroughPicturesAsset(pictures, recordName: change.recordName, digest: digest)
                    }
                }
            } else if let previous = previousAssetDigests[.walkthroughPicturesAsset], previous != absentAssetDigest {
                attachAsset(.walkthroughPicturesAsset, digest: absentAssetDigest) { _ in nil }
            }
        case .sourceHighlight:
            guard let payload = try store.loadSourceHighlightForSync(change.logicalKey) else {
                return nil
            }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .book:
            guard let payload = try store.loadBookForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
            // A cover this Mac cannot read is not evidence that the server's
            // asset should go. Books arrive as metadata long before (or without)
            // their files, so a coverless Mac republishing — which the one-time
            // nudge makes every Mac do — would strip the cover every other
            // device was showing. Same erasure `sourcePDFAsset` guards against
            // above: only a book that genuinely has no cover clears the field.
            if let readableCoverPath = readableBookCoverPath(payload.coverPath) {
                attachAsset(
                    .bookCoverAsset,
                    digest: fileDigest(readableCoverPath, variant: "cover-v1")
                ) { digest in
                    makeBookCoverAsset(
                        absolutePath: readableCoverPath,
                        recordName: change.recordName,
                        digest: digest
                    )
                }
            } else if payload.coverPath?.isEmpty != false {
                attachAsset(.bookCoverAsset, digest: absentAssetDigest) { _ in nil }
            }
        case .course:
            guard var payload = try store.loadCourseForSync(change.logicalKey) else { return nil }
            if change.home.isTeamZone {
                // A team's course is everyone's; whether one member hid it
                // from their Courses home is theirs (teams-design.md, decision
                // 21), and the inbound apply keeps each member's own.
                payload = CloudKitCoursePayload(
                    id: payload.id,
                    title: payload.title ?? payload.name,
                    courseCode: payload.courseCode,
                    institution: payload.institution,
                    instructors: payload.instructors,
                    playlistURL: payload.playlistURL,
                    isHidden: false,
                    pendingPlaylistImport: payload.pendingPlaylistImport,
                    lectures: payload.lectures,
                    lectureItems: payload.lectureItems,
                    quizzes: payload.quizzes,
                    sourceUnits: payload.sourceUnits
                )
            }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
            // The pictures the quizzes show from this Mac's image store —
            // drawn for a question, drawn in a chat, or made in another app
            // and kept with save_image — have no transport of their own (the
            // store is local, "Generated chat pictures" in
            // docs/backend-storage-sync.md), and the payload beside them is
            // already every quiz of the course. They ride as one package, to
            // the learner's other Macs and, in a team's zone, to its members.
            // While this Mac is drawing the course's pictures the field is left
            // alone, nothing attached and nothing staged: the run pins one
            // after another, and each send would otherwise upload the whole
            // package again. Its closing save sends it once.
            if !CourseQuizPicturePackage.isHoldingUploads(courseID: change.logicalKey) {
                let storedPictureIDs = CourseQuizPicturePackage.storedImageIDs(in: payload.quizzes ?? [])
                let pictureFiles = CourseQuizPicturePackage.localFiles(for: storedPictureIDs)
                if !pictureFiles.isEmpty {
                    attachAsset(
                        .courseQuizPicturesAsset,
                        digest: CourseQuizPicturePackage.digest(pictureFiles)
                    ) { digest in
                        makeCourseQuizPicturesAsset(files: pictureFiles, recordName: change.recordName, digest: digest)
                    }
                } else if storedPictureIDs.isEmpty,
                          let previous = previousAssetDigests[.courseQuizPicturesAsset], previous != absentAssetDigest {
                    // No quiz shows a stored picture any more. Only then is the
                    // package cleared: a Mac that merely lacks the files, or a
                    // course that never had any (a field the Production schema
                    // may not have yet), leaves the server's copy alone.
                    attachAsset(.courseQuizPicturesAsset, digest: absentAssetDigest) { _ in nil }
                }
            }
        case .videoPlaylist:
            guard let payload = try store.loadVideoPlaylistForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .meetingGroup:
            guard let payload = try store.loadMeetingGroupForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .hiddenSource:
            guard let payload = try store.loadHiddenSourceForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .hiddenPodcastShow:
            guard let payload = try store.loadHiddenPodcastShowForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .hiddenYouTubeChannel:
            guard let payload = try store.loadHiddenYouTubeChannelForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .hiddenArtifact:
            guard let payload = try store.loadHiddenArtifactForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .hiddenReviewSession:
            guard let payload = try store.loadHiddenReviewSessionForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .dismissedSource:
            guard let payload = try store.loadDismissedSourceForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .chatContext:
            guard let payload = try store.loadChatContextForSync() else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .reviewSession:
            guard let payload = try store.loadReviewSessionForSync(change.logicalKey) else { return nil }
            let encoded = try JSONEncoder().encode(payload)
            // A review session carries its whole transcript and, for a memory
            // review, the tutor's briefing over every source of the day. CloudKit
            // caps a record's fields at 1 MB, and on 2026-09-08 a briefing over
            // 166 sources plus 18 exchanges crossed it: "record too large",
            // parked, and no retry could ever shrink it. Past the inline limit
            // the same JSON travels as a `payloadAsset` instead — assets have no
            // such cap — and `payloadData(from:)` reads either form. Whichever
            // form a save takes, the other field is cleared, so a session that
            // grows across the line or is trimmed back under it never leaves a
            // stale copy for a receiver to prefer.
            if encoded.count <= Self.inlinePayloadByteLimit {
                record.encryptedValues[.payload] = encoded as NSData
                attachAsset(.payloadAsset, digest: absentAssetDigest, deferrable: false) { _ in nil }
            } else {
                record.encryptedValues[.payload] = nil
                try attachAsset(.payloadAsset, digest: dataDigest(encoded), deferrable: false) { digest in
                    try materializeAsset(
                        recordName: change.recordName,
                        suffix: "review-session",
                        fileExtension: "json",
                        digest: digest
                    ) { encoded }
                }
            }
        case .memoryItem:
            guard let payload = try store.loadMemoryItemForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .memoryAttempt:
            guard let payload = try store.loadMemoryAttemptForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .learningGoal:
            guard var payload = try store.loadLearningGoalForSync(change.logicalKey) else { return nil }
            if change.home.isTeamZone {
                // Membership and each item's approval are the team's; a
                // member's completions and quiz history are their own and
                // stay local.
                payload = CloudKitLearningGoalPayload(
                    goal: payload.goal.strippingMemberProgress(),
                    sourceIdentities: payload.sourceIdentities,
                    linkedCourseIDs: payload.linkedCourseIDs
                )
            }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .team:
            guard let payload = try store.loadTeamForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .notebookTask:
            guard let task = try store.loadNotebookTask(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(CloudKitNotebookTaskPayload(task: task)) as NSData
        case .shareRequest:
            guard let request = try store.loadShareRequest(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(CloudKitShareRequestPayload(request: request)) as NSData
        case .artifact:
            guard let artifact = try store.loadArtifactForSync(change.logicalKey) else { return nil }
            guard let package = try store.loadArtifactBodyPackageForSync(change.logicalKey) else {
                throw KnowledgeStoreError.invalidData(
                    "The Article body is unavailable or exceeds the CloudKit sync limit."
                )
            }
            try attachAsset(.payloadAsset, digest: package.revision) { digest in
                try materializeAsset(
                    recordName: change.recordName,
                    suffix: "article-body-v\(ArtifactBodyPackage.formatVersion)",
                    fileExtension: "fya",
                    digest: digest
                ) { package.data }
            }
            record.encryptedValues[.payload] = try JSONEncoder().encode(
                CloudKitArtifactPayload(
                    artifact: artifact,
                    bodyRevision: package.revision,
                    bodyByteCount: package.byteCount,
                    bodyFormatVersion: ArtifactBodyPackage.formatVersion,
                    walkthrough: try store.loadArtifactWalkthrough(change.logicalKey)
                )
            ) as NSData
        case .artifactComment:
            guard let comment = try store.loadArtifactCommentForSync(change.logicalKey) else {
                return nil
            }
            record.encryptedValues[.payload] = try JSONEncoder().encode(comment) as NSData
            record.parent = CKRecord.Reference(
                recordID: CKRecord.ID(
                    recordName: recordName(for: .artifact, logicalKey: comment.artifactID),
                    zoneID: change.home.zoneID
                ),
                action: .none
            )
        case .scheduledSource:
            guard let payload = try store.loadScheduledSourceForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .scheduledTask:
            guard let payload = try store.loadScheduledTaskForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .dayPlan:
            guard let payload = try store.loadDayPlanForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .idea:
            guard let payload = try store.loadIdeaForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .walkthroughProgress:
            guard let payload = try store.loadWalkthroughProgressForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .skill:
            guard let payload = try store.loadSkillForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .researchDirection:
            guard let payload = try store.loadResearchDirectionForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .videoCitedPaper:
            guard let payload = try store.loadVideoCitedPaperForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .sourceIdea:
            guard let payload = try store.loadSourceIdeaForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .memoryReviewActivity:
            guard let payload = try store.loadMemoryReviewActivityForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        case .researchCanvas:
            // Tombstoned: the ResearchCanvas feature was removed (folded into
            // Notebooks). Never upload new canvas records.
            return nil
        case .aiUsageEvent:
            guard let event = try store.loadAIUsageEventForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(CloudKitAIUsageEventPayload(event: event)) as NSData
        case .preference:
            guard let payload = try store.loadPreferenceForSync(change.logicalKey) else { return nil }
            record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
        }

        record.encryptedValues[.userModificationDate] = (metadata?.userModificationDate ?? change.changedAt) as NSDate
        return record
    }

    /// A fetched record applied the way the sync engine applies one that wins:
    /// the tutor merge where the entity has one, the plain apply otherwise. A
    /// record from a team zone is the team's copy, so the row is stamped with
    /// the team, and what this member has done with it — the columns a team
    /// record never carries (`KnowledgeStore.MemberStateSnapshot`) — is put
    /// back after the apply. Everything the record does carry follows the
    /// record, an item's approval in a team Notebook included.
    static func applyFetched(
        record: CKRecord,
        descriptor: CloudKitRecordDescriptor,
        home: CloudKitZoneHome,
        to store: KnowledgeStore
    ) throws -> CloudKitAppliedRecord {
        let memberState = home.isTeamZone
            ? try store.captureMemberState(entity: descriptor.entity, logicalKey: descriptor.logicalKey)
            : nil
        let applied = try mergeTutorServerConflict(
            record: record,
            to: store,
            preferLocalEditorial: false
        ) ?? apply(record: record, to: store)
        if let teamID = home.teamID {
            try store.withoutSyncTracking {
                try store.stampTeam(entity: applied.entity, logicalKey: applied.logicalKey, teamID: teamID)
                if let memberState { try store.restoreMemberState(memberState) }
            }
        }
        return applied
    }

    static func apply(
        record: CKRecord,
        to store: KnowledgeStore,
        sourceContentRoot: URL? = nil,
        durableImportRoot: URL? = nil
    ) throws -> CloudKitAppliedRecord {
        let descriptor = try descriptor(for: record)
        guard let payloadData = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        var requiresRepublish = false
        var appliedLogicalKey = descriptor.logicalKey

        switch descriptor.entity {
        case .source:
            let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)
            var article = payload.article
            let needsLocalSource = article.localFilePath?.isEmpty != false
                || (article.sourceType == .paper
                    && (article.paperIngestionMethod == nil
                        || article.paperAuthorNeedsEnrichment
                        || article.paperJournalNeedsEnrichment
                        || article.paperYearNeedsEnrichment))
            let localSource = needsLocalSource
                ? try store.loadSourceForSync(article.id)
                : nil
            if article.localFilePath?.isEmpty != false,
               let localFilePath = localSource?.localFilePath,
               !localFilePath.isEmpty {
                // Source files sync through iCloud Drive separately from their
                // CloudKit metadata. A device can therefore publish a source row
                // before it learns about an attachment another Mac already has.
                // Treat a missing inbound path as absent knowledge, not a detach:
                // only a non-empty remote path may replace a non-empty local one.
                article.localFilePath = localFilePath
                requiresRepublish = true
            }
            if article.sourceType == .paper {
                if let local = localSource,
                   article.retainCompletedPaperIngestion(from: local) {
                    requiresRepublish = true
                }
            }
            if article.sourceType == .paper, article.paperIngestionMethod == nil {
                // Payload v0 predates the durable attestation field. Match the
                // version-10 on-disk migration: a formerly-ready paper with all
                // required metadata is grandfathered once, rather than charging
                // for the same AI extraction again on every receiving Mac. New
                // payloads declare their version and still fail closed.
                if payload.payloadVersion == 0,
                   article.grandfatherLegacyPaperIngestionIfEligible() {
                    requiresRepublish = true
                }
                if article.paperIngestionMethod == nil, article.state == .ready {
                    // A ready paper with no attestation must not stay ready, and
                    // that demotion is a real change other devices need.
                    article.failPaperIngestionMetadata(
                        StudioArticle.missingPaperIngestionAttestationError
                    )
                    requiresRepublish = true
                }
                // Anything still here is an attestation-less paper already in a
                // safe non-ready state: republishing would send back exactly what
                // arrived, and that record returns on the next pass. Republishing
                // unconditionally is what re-uploaded 149 of this library's 158
                // attestation-less papers every hour, most of them archived, and
                // kept the sync badge permanently busy.
            }
            if article.sourceType == .video || article.sourceType == .meeting || article.isYouTubeURL {
                let local = try store.loadSourceProgress(sourceID: article.id)
                let mergedLocator = VideoWatchProgress.mergedSyncLocator(
                    remote: article.readingPositionLocator,
                    local: local?.locator
                )
                requiresRepublish = requiresRepublish || mergedLocator != article.readingPositionLocator
                // A copy from before this device's Mark as Not Watched carries
                // the read stamp that mark cleared; keep the cleared one.
                if let stamp = article.readAt,
                   let unwatchedAt = VideoWatchProgress.unwatchedEpoch(
                    in: local?.locator,
                    unseenBy: article.readingPositionLocator
                   ),
                   stamp <= unwatchedAt {
                    article.readAt = local?.readAt
                    requiresRepublish = true
                }
                article.readingPositionLocator = mergedLocator
            }
            // User dismissed this source locally — don't let CloudKit resurrect it.
            // Book chapters are exempt: their local-file URL must never be treated as
            // a dismissal (which would archive + content-wipe them on every sync).
            guard article.sourceType == .book || !store.isSourceDismissed(url: article.url) else {
                let archived = try store.withoutSyncTracking {
                    try store.archiveSourcesMatchingDismissedURL(article.url)
                }
                // `archiveSourcesMatchingDismissedURL` only matches *active*
                // sources and publishes what it archives. Finding none means this
                // one was already archived here on an earlier pass, so the local
                // archive still has to reach the server — but only if the server
                // does not already agree. The arriving record is that answer:
                // `archived` on the wire means our archive landed, and re-sending
                // it teaches CloudKit nothing.
                //
                // Republishing on `archived.isEmpty` alone is what made this Mac
                // re-upload every dismissed-and-archived source forever. Our own
                // save comes back on the next pass, lands here again, finds
                // nothing to archive again, and republishes again — a self-feeding
                // echo with no external input. It kept 107 sources cycling and the
                // sync badge permanently busy on an idle app.
                let serverStillSaysActive = article.status != .archived
                return CloudKitAppliedRecord(
                    entity: descriptor.entity,
                    logicalKey: descriptor.logicalKey,
                    userModificationDate: descriptor.userModificationDate,
                    requiresRepublish: archived.isEmpty && serverStillSaysActive
                )
            }
            if let materializedPDFPath = try materializeInboundWebPDFIfNeeded(
                payload: payload,
                record: record,
                sourceContentRoot: sourceContentRoot,
                durableImportRoot: durableImportRoot
                    ?? URL(fileURLWithPath: store.dbPath)
                        .deletingLastPathComponent()
                        .appendingPathComponent(".web-pdf-imports", isDirectory: true)
            ) {
                requiresRepublish = requiresRepublish
                    || article.localFilePath != materializedPDFPath
                article.localFilePath = materializedPDFPath
            } else {
                // Ordinary Mac-authored papers and chapters: the record carries
                // the document, and since content no longer travels through
                // CloudDocs, this is what puts it on disk. No republish — the
                // stored path was already correct, only the bytes were missing.
                materializeInboundSourcePDFIfNeeded(
                    article: article,
                    record: record,
                    sourceContentRoot: sourceContentRoot
                )
            }
            // The EPUB counterpart, and likewise no republish: the chapter's
            // path was already right, only its markup was missing.
            if article.sourceType == .book,
               let installedPath = installRecordedBookChapterDocument(
                   from: record,
                   storedPath: article.localFilePath,
                   sourceContentRoot: sourceContentRoot,
                   logicalKey: article.id
               ) {
                try? store.recordCommittedAssetDigest(
                    recordName: record.recordID.recordName,
                    field: CKRecord.FieldKey.sourceReaderHTMLAsset,
                    digest: recoveredReaderDocumentAssetDigest(atPath: installedPath)
                )
            }
            // No republish: the arriving path was already right on both Macs,
            // only the picture was missing.
            materializeInboundMeetingIconIfNeeded(
                article: article,
                record: record,
                sourceContentRoot: sourceContentRoot
            )
            if let materializedArchivePath = materializeInboundArchivedArticleIfNeeded(
                article: article,
                record: record,
                sourceContentRoot: sourceContentRoot
            ) {
                let incomingPortablePath = article.localFilePath.map(
                    StorageService.relativeSourcePath
                )
                requiresRepublish = requiresRepublish
                    || incomingPortablePath != materializedArchivePath
                article.localFilePath = materializedArchivePath
            }
            article.content = loadAssetString(from: record[.sourceContentAsset] as? CKAsset)
            // Metadata with no asset beside it is not a corrupt record. The
            // server copy inside a `.serverRecordChanged` error carries every
            // encrypted field and no asset bytes at all, and that is the record
            // this runs on when an oplock miss is resolved in the server's
            // favour. Throwing here parked nothing and settled nothing: the
            // refusal's bookkeeping failed, the row stayed queued, and 47
            // narrated sources on the release build retried every flush until
            // the engine backed off for half an hour (2026-09-01, build 39).
            // The branch below already knows what to do with a record that
            // has metadata and no text — keep the narration this Mac prepared
            // and republish it — so this simply lets it get there.
            let listenableContent = loadAssetString(
                from: record[.sourceListenableContentAsset] as? CKAsset
            )
            if article.sourceType == .paper,
               let raw = loadAssetString(from: record[.sourceRawContentAsset] as? CKAsset) {
                let preparation = payload.paperContentPreparation
                    ?? PaperContentPreparationMetadata(
                        cleanerVersion: PaperContentPreparationMetadata.deterministicVersion,
                        rawSHA256: PaperContentPreparationService.sha256(raw),
                        cleanSHA256: article.content.map(PaperContentPreparationService.sha256),
                        preparedAt: record.modificationDate
                    )
                guard PaperContentPreparationService.sha256(raw) == preparation.rawSHA256,
                      preparation.cleanSHA256 == nil
                        || article.content.map(PaperContentPreparationService.sha256) == preparation.cleanSHA256 else {
                    throw KnowledgeStoreError.invalidData(
                        "CloudKit paper content failed its integrity check for \(article.id)."
                    )
                }
                article.rawPaperContentForPersistence = raw
                article.paperContentPreparationForPersistence = preparation
                article.paperContentSHA256 = preparation.cleanerVersion
                    >= PaperContentPreparationMetadata.currentVersion
                    && preparation.cleanSHA256 != nil
                    ? preparation.rawSHA256
                    : nil
                requiresRepublish = requiresRepublish || payload.paperContentPreparation == nil
            }
            if article.sourceType == .paper,
               article.state == .ready,
               article.paperContentPreparationForPersistence == nil,
               let legacyRaw = article.content {
                let candidate = MacArticleSpeechText.narrationText(from: legacyRaw)
                let clean = candidate.isEmpty ? legacyRaw : candidate
                article.installPreparedPaperContent(
                    raw: legacyRaw,
                    clean: clean,
                    metadata: PaperContentPreparationMetadata(
                        cleanerVersion: PaperContentPreparationMetadata.deterministicVersion,
                        rawSHA256: PaperContentPreparationService.sha256(legacyRaw),
                        cleanSHA256: PaperContentPreparationService.sha256(clean),
                        preparedAt: Date()
                    )
                )
                requiresRepublish = true
            }
            if article.sourceType == .article
                || article.sourceType == .manual
                || article.sourceType == .unclassified,
               let raw = loadAssetString(from: record[.sourceRawContentAsset] as? CKAsset) {
                let preparation = payload.articleContentPreparation
                    ?? PaperContentPreparationMetadata(
                        cleanerVersion: PaperContentPreparationMetadata.deterministicVersion,
                        rawSHA256: PaperContentPreparationService.sha256(raw),
                        cleanSHA256: article.content.map(PaperContentPreparationService.sha256),
                        preparedAt: record.modificationDate
                    )
                guard PaperContentPreparationService.sha256(raw) == preparation.rawSHA256,
                      preparation.cleanSHA256 == nil
                        || article.content.map(PaperContentPreparationService.sha256) == preparation.cleanSHA256 else {
                    throw KnowledgeStoreError.invalidData(
                        "CloudKit article content failed its integrity check for \(article.id)."
                    )
                }
                article.rawArticleContentForPersistence = raw
                article.articleContentPreparationForPersistence = preparation
                requiresRepublish = requiresRepublish || payload.articleContentPreparation == nil
            }
            // The cleanup is checked against the bytes it names, and only when the record carries both: a
            // record fetched for its payload alone (the migration catch-up's walk leaves every file asset for
            // after the activation) has no transcript to check, so this Mac keeps its own transcript and
            // cleanup, as the paper and article branches above keep theirs.
            if article.sourceType == .podcast,
               let metadata = payload.podcastTranscriptCleanup,
               let input = loadAssetString(from: record[.sourceRawContentAsset] as? CKAsset),
               let clean = article.content {
                guard PaperContentPreparationService.sha256(input) == metadata.inputSHA256,
                      PaperContentPreparationService.sha256(clean) == metadata.cleanSHA256 else {
                    throw KnowledgeStoreError.invalidData(
                        "CloudKit podcast transcript cleanup failed its integrity check for \(article.id)."
                    )
                }
                article.podcastTranscriptInputForPersistence = input
                article.podcastTranscriptCleanupForPersistence = metadata
            }
            try store.withoutSyncTracking {
                if article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    if let existingContent = try store.loadSourceContent(article.id) {
                        article.content = existingContent
                    } else {
                        article.content = try store.loadLocalDuplicateContent(of: article)
                    }
                }
                if article.state == .ready,
                   article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    // Accept the record without letting it violate the local
                    // CarPlay/readability contract, and keep the demotion local.
                    // An unset `sourceContentAsset` is the normal shape of a
                    // modification — the outbound gate leaves the field alone so
                    // CloudKit keeps the copy it already has — so "no asset in this
                    // fetch" cannot be read as "no asset in the library". Marking
                    // this for republish pushed one device's gap out as a `queued`
                    // verdict and demoted healthy sources everywhere. Local
                    // re-ingestion publishes real content on success instead.
                    article.state = .queued
                    article.errorMessage = nil
                }
                try store.deleteLocalDuplicate(of: article)
                try store.saveSourceFromSync(article, portableIdentity: payload.sourceIdentity)
                if let reviewDepth = payload.reviewDepth {
                    try store.saveSourceReviewDepthFromSync(sourceID: article.id, depth: reviewDepth)
                }
                if let metadata = payload.listenableContentMetadata,
                   let listenableContent {
                    try store.saveSourceListenableContentFromSync(
                        sourceID: article.id,
                        content: listenableContent,
                        metadata: metadata
                    )
                } else if payload.hasListenableContentPayload,
                          try store.loadSourceListenableContent(article.id) != nil {
                    // Preserve a valid derivative prepared on this device rather
                    // than letting a peer that has not drained its queue erase it.
                    requiresRepublish = true
                }
                try store.saveSourceReviewGuideFromSync(
                    sourceID: article.id,
                    guide: payload.sourceReviewGuide
                )
                try store.savePaperWalkthroughFromSync(
                    sourceID: article.id,
                    walkthrough: payload.paperWalkthrough
                )
                if payload.hasPaperFiguresPayload {
                    try store.savePaperFiguresFromSync(
                        sourceID: article.id,
                        figures: payload.paperFigures
                    )
                }
                if payload.hasSourceUnitsPayload {
                    try store.saveSourceUnitsRecord(sourceID: article.id, units: payload.sourceUnits)
                }
                if let rawTTML = loadAssetString(from: record[.podcastRawTTMLAsset] as? CKAsset) {
                    try store.saveRawTTML(article.id, rawTTML)
                }
                if article.sourceType == .podcast {
                    try store.setPodcastEpisodeVisibleOverride(article.id, visible: payload.visiblePodcastEpisodeOverride)
                }
                if article.sourceType == .video, article.isYouTubeURL {
                    try store.setYouTubeVideoVisibleOverride(article.id, visible: payload.visibleYouTubeVideoOverride)
                }
            }
            // The walk's drawn pictures arrive beside the payload; each lands
            // in this Mac's image store unless it is there already.
            if let asset = record[.walkthroughPicturesAsset] as? CKAsset, let packageURL = asset.fileURL {
                let arrived = WalkthroughPicturePackage.materialize(packageAt: packageURL, root: sourceContentRoot)
                StoredPicturePackage.announceArrival(of: arrived, root: sourceContentRoot)
            }
        case .sourceHighlight:
            let payload = try JSONDecoder().decode(
                CloudKitSourceHighlightPayload.self,
                from: payloadData
            )
            appliedLogicalKey = try store.withoutSyncTracking {
                try store.saveSourceHighlightRecord(payload)
            }
        case .book:
            var payload = try JSONDecoder().decode(CloudKitBookPayload.self, from: payloadData)
            // Book records arrive independently from their chapter files. The
            // cover asset is the reliable preview while those files are absent
            // or still downloading, so a receiving Mac must install it too.
            if let localCoverPath = materializeInboundBookCoverIfNeeded(
                payload: payload,
                record: record,
                sourceContentRoot: sourceContentRoot
            ) {
                payload = CloudKitBookPayload(
                    id: payload.id,
                    title: payload.title,
                    subtitle: payload.subtitle,
                    author: payload.author,
                    edition: payload.edition,
                    coverPath: localCoverPath,
                    kind: payload.kind
                )
            }
            try store.withoutSyncTracking {
                try store.saveBookRecord(payload)
            }
        case .course:
            let payload = try JSONDecoder().decode(CloudKitCoursePayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveCourseGroup(
                    name: payload.id,
                    metadata: CourseMetadata(
                        courseCode: payload.courseCode,
                        title: payload.title,
                        institution: payload.institution,
                        instructors: payload.instructors,
                        playlistURL: payload.playlistURL,
                        isHidden: payload.isHidden,
                        pendingPlaylistImport: payload.pendingPlaylistImport
                    )
                )
                if !payload.lectures.isEmpty {
                    let lectures = payload.lectures.map { lecture in
                        var lecture = lecture
                        lecture.courseName = payload.id
                        return lecture
                    }
                    // A reading's unit first, so the item naming it can land.
                    if let units = payload.sourceUnits, !units.isEmpty {
                        try store.upsertSourceUnitsFromSync(units)
                    }
                    try store.saveCourseOutline(
                        courseName: payload.id,
                        lectures: lectures,
                        items: payload.lectureItems
                    )
                }
                if let quizzes = payload.quizzes {
                    try store.replaceCourseQuizzesFromSync(courseID: payload.id, quizzes: quizzes)
                }
            }
            // The quizzes' stored pictures arrive beside the payload; each
            // lands in this Mac's image store unless it is there already.
            if let asset = record[.courseQuizPicturesAsset] as? CKAsset, let packageURL = asset.fileURL {
                let arrived = CourseQuizPicturePackage.materialize(packageAt: packageURL, root: sourceContentRoot)
                StoredPicturePackage.announceArrival(of: arrived, root: sourceContentRoot)
            }
        case .videoPlaylist:
            let payload = try JSONDecoder().decode(CloudKitVideoPlaylistPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveVideoPlaylistGroup(id: payload.id, metadata: payload.metadata)
            }
        case .meetingGroup:
            let payload = try JSONDecoder().decode(CloudKitMeetingGroupPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveMeetingGroup(name: payload.id, metadata: payload.metadata)
                try store.saveMeetingArtifactsRecord(groupID: payload.id, artifacts: payload.artifacts)
                if let items = payload.actionItems {
                    try store.mergeMeetingActionItemsRecord(groupID: payload.id, items: items)
                }
            }
        case .hiddenSource:
            let payload = try JSONDecoder().decode(CloudKitHiddenSourcePayload.self, from: payloadData)
            _ = try store.withoutSyncTracking {
                try store.saveHiddenSourceRecord(payload)
            }
        case .hiddenPodcastShow:
            let payload = try JSONDecoder().decode(CloudKitHiddenPodcastShowPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveHiddenPodcastShowRecord(payload)
            }
        case .hiddenYouTubeChannel:
            let payload = try JSONDecoder().decode(CloudKitHiddenYouTubeChannelPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveHiddenYouTubeChannelRecord(payload)
            }
        case .hiddenArtifact:
            let payload = try JSONDecoder().decode(CloudKitHiddenArtifactPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveHiddenArtifactRecord(payload)
            }
        case .hiddenReviewSession:
            let payload = try JSONDecoder().decode(CloudKitHiddenReviewSessionPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveHiddenReviewSessionRecord(payload)
            }
        case .dismissedSource:
            let payload = try JSONDecoder().decode(CloudKitDismissedSourcePayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveDismissedSourceRecord(payload)
            }
        case .chatContext:
            let payload = try JSONDecoder().decode(CloudKitChatContextPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveChatContextRecord(payload)
            }
        case .reviewSession:
            let payload = try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveReviewSessionRecord(payload)
            }
        case .memoryItem:
            let payload = try JSONDecoder().decode(CloudKitMemoryItemPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveMemoryItemRecord(payload)
            }
        case .memoryAttempt:
            let payload = try JSONDecoder().decode(CloudKitMemoryAttemptPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveMemoryAttemptRecord(payload)
            }
        case .learningGoal:
            let payload = try JSONDecoder().decode(CloudKitLearningGoalPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveLearningGoalRecord(payload)
            }
        case .artifact:
            let payload = try JSONDecoder().decode(CloudKitArtifactPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                if let asset = record[.payloadAsset] as? CKAsset,
                   let assetURL = asset.fileURL {
                    let bodyData = try Data(contentsOf: assetURL, options: [.mappedIfSafe])
                    if let declaredByteCount = payload.bodyByteCount,
                       declaredByteCount != bodyData.count {
                        throw KnowledgeStoreError.invalidData(
                            "The synced Article body has an unexpected byte count."
                        )
                    }
                    let revision = try store.saveArtifactBodyPackageFromSync(
                        bodyData,
                        artifactID: payload.artifact.id,
                        expectedRevision: payload.bodyRevision
                    )
                    try store.stageAssetDigests(
                        [.payloadAsset: revision],
                        recordName: record.recordID.recordName
                    )
                    try store.commitStagedAssetDigests(recordName: record.recordID.recordName)
                } else if let markdown = payload.markdown {
                    // Legacy decode-only path. Preserve the historical body,
                    // then immediately publish it through the sole v1 asset
                    // transport without pretending the old envelope is current.
                    try store.saveArtifactMarkdownFromSync(markdown, artifactID: payload.artifact.id)
                    requiresRepublish = true
                } else if try store.loadArtifactMarkdownForSync(payload.artifact.id) != nil {
                    // An early metadata-only record has no body opinion. Keep the
                    // readable local body and enroll it in the new transport.
                    requiresRepublish = true
                } else {
                    throw KnowledgeStoreError.invalidData(
                        "The synced Article is missing its body asset."
                    )
                }
                try store.saveArtifactRecord(payload.artifact)
                try store.saveArtifactWalkthroughFromSync(artifactID: payload.artifact.id, walkthrough: payload.walkthrough)
            }
        case .artifactComment:
            let comment = try JSONDecoder().decode(ArtifactCommentRecord.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveArtifactCommentRecord(comment)
            }
        case .scheduledSource:
            let payload = try JSONDecoder().decode(CloudKitScheduledSourcePayload.self, from: payloadData)
            let merge = try store.withoutSyncTracking {
                try store.saveScheduledSourceRecord(payload)
            }
            appliedLogicalKey = merge.logicalKey
            requiresRepublish = requiresRepublish || merge.requiresRepublish
        case .scheduledTask:
            let payload = try JSONDecoder().decode(CloudKitScheduledTaskPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveScheduledTaskRecord(payload)
            }
        case .dayPlan:
            let payload = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveDayPlanRecord(payload)
            }
        case .idea:
            let payload = try JSONDecoder().decode(CloudKitIdeaPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveIdeaRecord(payload)
            }
        case .walkthroughProgress:
            let payload = try JSONDecoder().decode(CloudKitWalkthroughProgressPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveWalkthroughProgressRecord(payload)
            }
        case .skill:
            let payload = try JSONDecoder().decode(CloudKitSkillPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveSkillRecord(payload)
            }
        case .researchDirection:
            let payload = try JSONDecoder().decode(CloudKitResearchDirectionPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveResearchDirectionRecord(payload)
            }
        case .sourceIdea:
            let payload = try JSONDecoder().decode(CloudKitSourceIdeaPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveSourceIdeaRecord(payload)
            }
        case .memoryReviewActivity:
            let payload = try JSONDecoder().decode(CloudKitMemoryReviewActivityPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveMemoryReviewActivityRecord(payload)
            }
        case .videoCitedPaper:
            let payload = try JSONDecoder().decode(CloudKitVideoCitedPaperPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveVideoCitedPaperRecord(payload)
            }
        case .researchCanvas:
            // Tombstoned: ignore inbound ResearchCanvas records from older clients.
            break
        case .aiUsageEvent:
            let payload = try JSONDecoder().decode(CloudKitAIUsageEventPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveAIUsageEventRecord(payload.event)
            }
        case .preference:
            let payload = try JSONDecoder().decode(CloudKitPreferencePayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.savePreferenceRecord(payload)
            }
        case .team:
            let payload = try JSONDecoder().decode(CloudKitTeamPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.applyTeamRecordFromSync(payload)
            }
        case .notebookTask:
            let payload = try JSONDecoder().decode(CloudKitNotebookTaskPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveNotebookTaskRecord(payload.task)
            }
        case .shareRequest:
            let payload = try JSONDecoder().decode(CloudKitShareRequestPayload.self, from: payloadData)
            try store.withoutSyncTracking {
                try store.saveShareRequestRecord(payload.request)
            }
        }

        return CloudKitAppliedRecord(
            entity: descriptor.entity,
            logicalKey: appliedLogicalKey,
            userModificationDate: descriptor.userModificationDate,
            requiresRepublish: requiresRepublish
        )
    }

    /// Merge tutor state for a true CloudKit save conflict. Whole-record LWW is
    /// unsafe for these entities: an offline editorial edit must not erase a
    /// completion, quiz counter, deterministic gap, or Schedule membership that
    /// another device committed while it was offline.
    ///
    /// nil means the entity has no tutor-specific merge and should follow the
    /// ordinary generic conflict path.
    static func mergeTutorServerConflict(
        record: CKRecord,
        to store: KnowledgeStore,
        preferLocalEditorial: Bool
    ) throws -> CloudKitAppliedRecord? {
        let descriptor = try descriptor(for: record)
        guard let payloadData = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        switch descriptor.entity {
        case .learningGoal:
            let payload = try JSONDecoder().decode(
                CloudKitLearningGoalPayload.self,
                from: payloadData
            )
            let requiresRepublish = try store.withoutSyncTracking {
                try store.mergeLearningGoalServerConflict(
                    payload,
                    preferLocalEditorial: preferLocalEditorial
                )
            }
            return CloudKitAppliedRecord(
                entity: descriptor.entity,
                logicalKey: descriptor.logicalKey,
                userModificationDate: descriptor.userModificationDate,
                requiresRepublish: requiresRepublish
            )
        case .scheduledSource:
            let payload = try JSONDecoder().decode(
                CloudKitScheduledSourcePayload.self,
                from: payloadData
            )
            let merged = try store.withoutSyncTracking {
                try store.mergeScheduledSourceServerConflict(
                    payload,
                    preferLocalEditorial: preferLocalEditorial
                )
            }
            return CloudKitAppliedRecord(
                entity: descriptor.entity,
                logicalKey: merged.logicalKey,
                userModificationDate: descriptor.userModificationDate,
                requiresRepublish: merged.requiresRepublish
            )
        default:
            return nil
        }
    }

    /// A server Doc body merged over a newer local one. See
    /// `mergeArtifactServerConflict`.
    struct ArtifactServerMerge: Sendable {
        enum Outcome: Sendable {
            /// The local body already read as the server's does.
            case identical
            /// Both sides' changes were combined into the local body.
            case merged
            /// The same passage changed on both sides. The local body stands and
            /// the server's is held beside it for the writer to choose.
            case heldForChoice
        }
        let applied: CloudKitAppliedRecord
        let outcome: Outcome
    }

    /// A Doc body arrived from CloudKit while this Mac has a newer body of its
    /// own waiting to upload — two team members writing at once. Last-writer-
    /// wins would silently drop one of them, and skipping the record would lose
    /// the server's edit for good (a skipped change is never redelivered), so
    /// the two are merged line by line against the body this device last knew
    /// the server to hold. A clean merge becomes the local body, still queued
    /// to upload; a conflict keeps the local body and holds the server's beside
    /// it for the Docs pane to offer. Either way the server's body is now the
    /// base, and the caller adopts the server record's change tag so the next
    /// upload lands. nil when the record carries no readable body or this Mac
    /// has none: the ordinary path applies then.
    static func mergeArtifactServerConflict(
        record: CKRecord,
        to store: KnowledgeStore
    ) throws -> ArtifactServerMerge? {
        let descriptor = try descriptor(for: record)
        guard descriptor.entity == .artifact,
              let payloadData = payloadData(from: record) else { return nil }
        let payload = try JSONDecoder().decode(CloudKitArtifactPayload.self, from: payloadData)
        let artifactID = payload.artifact.id
        let theirs: String
        if let asset = record[.payloadAsset] as? CKAsset,
           let assetURL = asset.fileURL,
           let bodyData = try? Data(contentsOf: assetURL, options: [.mappedIfSafe]) {
            theirs = try ArtifactBodyPackage.decode(bodyData, expectedRevision: payload.bodyRevision).markdown
        } else if let markdown = payload.markdown {
            theirs = markdown
        } else {
            return nil
        }
        guard let mine = try store.loadArtifactMarkdownForSync(artifactID) else { return nil }
        let applied = CloudKitAppliedRecord(
            entity: .artifact,
            logicalKey: artifactID,
            userModificationDate: descriptor.userModificationDate,
            requiresRepublish: false
        )
        if mine == theirs {
            try store.withoutSyncTracking { try store.saveArtifactBaseMarkdown(theirs, artifactID: artifactID) }
            return ArtifactServerMerge(applied: applied, outcome: .identical)
        }
        // A source's draft deck only grows: two Macs that drafted for the
        // same source before syncing keep both sets of cards, card by card.
        // A deck is never opened as a Doc, so a body held for a choice would
        // be held for good.
        if payload.artifact.isCardDeck,
           let union = FlashcardDeck.union(mine: mine, theirs: theirs) {
            try store.withoutSyncTracking { try store.saveArtifactBaseMarkdown(theirs, artifactID: artifactID) }
            if union != mine {
                try store.saveArtifactMarkdownAfterMerge(union, artifactID: artifactID)
            }
            return ArtifactServerMerge(applied: applied, outcome: union == theirs ? .identical : .merged)
        }
        // A mnemonic reading only grows too: two devices that wrote a
        // source's questions before syncing (a run here, a retry there) keep
        // every question, question by question. A reading is never edited as
        // a Doc either.
        if payload.artifact.kind == .mnemonicReading || payload.artifact.kind == nil,
           let union = MnemonicReading.union(mine: mine, theirs: theirs) {
            try store.withoutSyncTracking { try store.saveArtifactBaseMarkdown(theirs, artifactID: artifactID) }
            if union != mine {
                try store.saveArtifactMarkdownAfterMerge(union, artifactID: artifactID)
            }
            return ArtifactServerMerge(applied: applied, outcome: union == theirs ? .identical : .merged)
        }
        let base = try store.loadArtifactBaseMarkdown(artifactID)
        if let base, case .merged(let merged) = ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) {
            try store.withoutSyncTracking { try store.saveArtifactBaseMarkdown(theirs, artifactID: artifactID) }
            if merged != mine {
                try store.saveArtifactMarkdownAfterMerge(merged, artifactID: artifactID)
            }
            return ArtifactServerMerge(applied: applied, outcome: merged == theirs ? .identical : .merged)
        }
        try store.withoutSyncTracking {
            try store.saveArtifactHeldRemoteMarkdown(theirs, artifactID: artifactID)
            try store.saveArtifactBaseMarkdown(theirs, artifactID: artifactID)
        }
        return ArtifactServerMerge(applied: applied, outcome: .heldForChoice)
    }

    /// Merge an inbound source over a local copy whose only pending change is
    /// reading progress.
    ///
    /// Whole-record last-writer-wins is wrong for sources because the learner
    /// does not author most source writes. Opening an article stamps a scroll
    /// offset; finishing one stamps `read_at`. Either makes the local row newer
    /// than a rename another Mac published minutes earlier, and the generic skip
    /// then drops that rename for good — the change token has moved on, so the
    /// record never arrives again — and republishes the stale title over it.
    ///
    /// So take the server record whole, then put this device's progress back:
    /// the remote owns the metadata the learner edited there, this device owns
    /// the position it is reading from. A video's progress is put back through
    /// the watch-progress join rather than over the server's: a Mark as Not
    /// Watched the server already holds must not be undone by this device's
    /// older watching, nor by a read stamp made here before it, and a video
    /// this device has no progress for keeps the server's. Returns nil for any
    /// other entity.
    static func mergeSourceProgressServerConflict(
        record: CKRecord,
        to store: KnowledgeStore,
        sourceContentRoot: URL? = nil,
        durableImportRoot: URL? = nil
    ) throws -> CloudKitAppliedRecord? {
        let descriptor = try descriptor(for: record)
        guard descriptor.entity == .source else { return nil }
        let local = try store.loadSourceForSync(descriptor.logicalKey)
        let applied = try apply(
            record: record,
            to: store,
            sourceContentRoot: sourceContentRoot,
            durableImportRoot: durableImportRoot
        )
        guard let local, applied.logicalKey == descriptor.logicalKey else { return applied }
        let server = try store.loadSourceProgress(sourceID: descriptor.logicalKey)
        let locator = VideoWatchProgress.mergedLocator(
            owner: local.readingPositionLocator,
            other: server?.locator
        )
        var readAt = local.readAt
        if let stamp = readAt,
           let unwatchedAt = VideoWatchProgress.unwatchedEpoch(
            in: server?.locator,
            unseenBy: local.readingPositionLocator
           ),
           stamp <= unwatchedAt {
            readAt = server?.readAt
        }
        let restored = try store.withoutSyncTracking {
            try store.restoreSourceReadingProgress(
                sourceID: descriptor.logicalKey,
                page: local.readingPositionPage,
                locator: locator,
                readAt: readAt
            )
        }
        return CloudKitAppliedRecord(
            entity: applied.entity,
            logicalKey: applied.logicalKey,
            userModificationDate: applied.userModificationDate,
            requiresRepublish: applied.requiresRepublish || restored
        )
    }

    /// The generic local-newer retry is valid for mutable LWW records, but not
    /// for deterministic create-once curriculum or immutable learner evidence.
    /// Validate equality before adopting the server change tag; the engine
    /// quarantines a mismatch durably outside the active retry queue rather than
    /// ever overwriting the server winner.
    static func validateLocalNewerImmutableConflict(
        record: CKRecord,
        to store: KnowledgeStore
    ) throws {
        let descriptor = try descriptor(for: record)
        guard descriptor.entity == .memoryItem || descriptor.entity == .memoryAttempt else {
            return
        }
        guard let payloadData = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        do {
            switch descriptor.entity {
            case .memoryItem:
                try store.requireMatchingImmutableMemoryItemRecord(
                    JSONDecoder().decode(CloudKitMemoryItemPayload.self, from: payloadData)
                )
            case .memoryAttempt:
                try store.requireMatchingImmutableMemoryAttemptRecord(
                    JSONDecoder().decode(CloudKitMemoryAttemptPayload.self, from: payloadData)
                )
            default:
                break
            }
        } catch {
            throw CloudKitSyncError.immutableRecordConflict(
                entity: descriptor.entity.rawValue,
                logicalKey: descriptor.logicalKey,
                detail: error.localizedDescription
            )
        }
    }

    /// Adopt CloudKit's deterministic MemoryItem winner while preserving a
    /// divergent local curriculum under a retired archive identity. Returns nil
    /// for other entity types, whose immutable conflicts remain quarantined.
    static func adoptDivergentMemoryItemServerWinner(
        record: CKRecord,
        to store: KnowledgeStore
    ) throws -> CloudKitAppliedRecord? {
        let descriptor = try descriptor(for: record)
        guard descriptor.entity == .memoryItem else { return nil }
        guard let payloadData = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        let payload = try JSONDecoder().decode(
            CloudKitMemoryItemPayload.self,
            from: payloadData
        )
        _ = try store.withoutSyncTracking {
            try store.adoptServerMemoryItemResolvingCurriculumConflict(
                payload,
                resolvedAt: descriptor.userModificationDate
            )
        }
        return CloudKitAppliedRecord(
            entity: .memoryItem,
            logicalKey: descriptor.logicalKey,
            userModificationDate: descriptor.userModificationDate,
            requiresRepublish: false
        )
    }

    static func descriptor(for record: CKRecord) throws -> CloudKitRecordDescriptor {
        guard let entity = CloudKitSyncEntity.from(recordType: record.recordType) else {
            throw CloudKitSyncError.unsupportedRecordType(record.recordType)
        }
        guard let payloadData = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }

        let modifiedAt = (record.encryptedValues[.userModificationDate] as? Date)
            ?? record.modificationDate
            ?? Date()

        switch entity {
        case .source:
            let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.article.id, userModificationDate: modifiedAt)
        case .sourceHighlight:
            let payload = try JSONDecoder().decode(
                CloudKitSourceHighlightPayload.self,
                from: payloadData
            )
            return CloudKitRecordDescriptor(
                entity: entity,
                logicalKey: payload.highlight.id,
                userModificationDate: modifiedAt
            )
        case .book:
            let payload = try JSONDecoder().decode(CloudKitBookPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .course:
            let payload = try JSONDecoder().decode(CloudKitCoursePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .videoPlaylist:
            let payload = try JSONDecoder().decode(CloudKitVideoPlaylistPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .meetingGroup:
            let payload = try JSONDecoder().decode(CloudKitMeetingGroupPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .hiddenSource:
            let payload = try JSONDecoder().decode(CloudKitHiddenSourcePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.sourceID, userModificationDate: modifiedAt)
        case .hiddenPodcastShow:
            let payload = try JSONDecoder().decode(CloudKitHiddenPodcastShowPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.showName, userModificationDate: modifiedAt)
        case .hiddenYouTubeChannel:
            let payload = try JSONDecoder().decode(CloudKitHiddenYouTubeChannelPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.channelName, userModificationDate: modifiedAt)
        case .hiddenArtifact:
            let payload = try JSONDecoder().decode(CloudKitHiddenArtifactPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.artifactID, userModificationDate: modifiedAt)
        case .hiddenReviewSession:
            let payload = try JSONDecoder().decode(CloudKitHiddenReviewSessionPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.sessionID, userModificationDate: modifiedAt)
        case .dismissedSource:
            let payload = try JSONDecoder().decode(CloudKitDismissedSourcePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.url, userModificationDate: modifiedAt)
        case .chatContext:
            let payload = try JSONDecoder().decode(CloudKitChatContextPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.key, userModificationDate: modifiedAt)
        case .reviewSession:
            let payload = try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .memoryItem:
            let payload = try JSONDecoder().decode(CloudKitMemoryItemPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.item.id, userModificationDate: modifiedAt)
        case .memoryAttempt:
            let payload = try JSONDecoder().decode(CloudKitMemoryAttemptPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.attempt.id, userModificationDate: modifiedAt)
        case .learningGoal:
            let payload = try JSONDecoder().decode(CloudKitLearningGoalPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.goal.id, userModificationDate: modifiedAt)
        case .artifact:
            let payload = try JSONDecoder().decode(CloudKitArtifactPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.artifact.id, userModificationDate: modifiedAt)
        case .artifactComment:
            let payload = try JSONDecoder().decode(ArtifactCommentRecord.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .scheduledSource:
            let payload = try JSONDecoder().decode(CloudKitScheduledSourcePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.placement.id, userModificationDate: modifiedAt)
        case .scheduledTask:
            let payload = try JSONDecoder().decode(CloudKitScheduledTaskPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.task.id, userModificationDate: modifiedAt)
        case .dayPlan:
            let payload = try JSONDecoder().decode(CloudKitDayPlanPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.plan.id, userModificationDate: modifiedAt)
        case .idea:
            let payload = try JSONDecoder().decode(CloudKitIdeaPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.idea.id, userModificationDate: modifiedAt)
        case .walkthroughProgress:
            let payload = try JSONDecoder().decode(CloudKitWalkthroughProgressPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.progress.subjectID, userModificationDate: modifiedAt)
        case .skill:
            let payload = try JSONDecoder().decode(CloudKitSkillPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.skill.id, userModificationDate: modifiedAt)
        case .researchDirection:
            let payload = try JSONDecoder().decode(CloudKitResearchDirectionPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.direction.id, userModificationDate: modifiedAt)
        case .sourceIdea:
            let payload = try JSONDecoder().decode(CloudKitSourceIdeaPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.idea.id, userModificationDate: modifiedAt)
        case .memoryReviewActivity:
            let payload = try JSONDecoder().decode(CloudKitMemoryReviewActivityPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.activity.id, userModificationDate: modifiedAt)
        case .videoCitedPaper:
            let payload = try JSONDecoder().decode(CloudKitVideoCitedPaperPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.paper.id, userModificationDate: modifiedAt)
        case .researchCanvas:
            // Tombstoned: derive a logical key from the record name (payload no longer decodable).
            return CloudKitRecordDescriptor(entity: entity, logicalKey: record.recordID.recordName, userModificationDate: modifiedAt)
        case .aiUsageEvent:
            let payload = try JSONDecoder().decode(CloudKitAIUsageEventPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.event.id, userModificationDate: modifiedAt)
        case .preference:
            let payload = try JSONDecoder().decode(CloudKitPreferencePayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.key, userModificationDate: modifiedAt)
        case .team:
            let payload = try JSONDecoder().decode(CloudKitTeamPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.id, userModificationDate: modifiedAt)
        case .notebookTask:
            let payload = try JSONDecoder().decode(CloudKitNotebookTaskPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.task.id, userModificationDate: modifiedAt)
        case .shareRequest:
            let payload = try JSONDecoder().decode(CloudKitShareRequestPayload.self, from: payloadData)
            return CloudKitRecordDescriptor(entity: entity, logicalKey: payload.request.id, userModificationDate: modifiedAt)
        }
    }

    static func descriptorForSentRecord(_ record: CKRecord, store: KnowledgeStore) throws -> CloudKitRecordDescriptor {
        do {
            return try descriptor(for: record)
        } catch CloudKitSyncError.missingPayload(_) {
            guard let metadata = try store.loadSyncMetadata(recordName: record.recordID.recordName) else {
                throw CloudKitSyncError.missingPayload(record.recordID.recordName)
            }
            guard CloudKitSyncEntity.from(recordType: record.recordType) == metadata.entity else {
                throw CloudKitSyncError.unsupportedRecordType(record.recordType)
            }
            return CloudKitRecordDescriptor(
                entity: metadata.entity,
                logicalKey: metadata.logicalKey,
                userModificationDate: metadata.userModificationDate
            )
        }
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            return CKRecord(coder: unarchiver)
        } catch {
            return nil
        }
    }

    static func encodedPayloadData(from record: CKRecord) -> Data? {
        payloadData(from: record)
    }

    static func memoryAttemptParentItemID(from record: CKRecord) throws -> String? {
        guard CloudKitSyncEntity.from(recordType: record.recordType) == .memoryAttempt else {
            return nil
        }
        guard let data = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        return try JSONDecoder()
            .decode(CloudKitMemoryAttemptPayload.self, from: data)
            .attempt
            .memoryItemID
    }

    static func memoryAttemptParentCurriculumFingerprint(
        from record: CKRecord
    ) throws -> String? {
        guard CloudKitSyncEntity.from(recordType: record.recordType) == .memoryAttempt else {
            return nil
        }
        guard let data = payloadData(from: record) else {
            throw CloudKitSyncError.missingPayload(record.recordID.recordName)
        }
        let payload = try JSONDecoder().decode(
            CloudKitMemoryAttemptPayload.self,
            from: data
        )
        if payload.payloadVersion >= 2 {
            guard let fingerprint = payload.parentCurriculumFingerprint,
                  !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudKitSyncError.immutableRecordConflict(
                    entity: CloudKitSyncEntity.memoryAttempt.rawValue,
                    logicalKey: payload.attempt.id,
                    detail: "Version 2 MemoryAttempt payload is missing its parent curriculum fingerprint."
                )
            }
            return fingerprint
        }
        return payload.parentCurriculumFingerprint
    }

    /// A record's payload, its keys as this build names them (`RetiredNotebookWording`).
    private static func payloadData(from record: CKRecord) -> Data? {
        storedPayloadData(from: record).map(RetiredNotebookWording.currentPayload)
    }

    private static func storedPayloadData(from record: CKRecord) -> Data? {
        if let data = record.encryptedValues[.payload] as? Data {
            return data
        }
        if let data = record.encryptedValues[.payload] as? NSData {
            return data as Data
        }
        if let asset = record[.payloadAsset] as? CKAsset,
           let url = asset.fileURL {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    // MARK: - Asset change detection

    /// Stands in for "this field has no asset", so a source that loses its PDF
    /// still clears the server copy instead of looking unchanged.
    private static let absentAssetDigest = "-"

    /// Digest for an asset built from text already in memory — hashing it costs
    /// nothing beyond what encoding it would have.
    private static func textDigest(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return absentAssetDigest }
        return dataDigest(Data(string.utf8))
    }

    /// The same digest over bytes already in memory, for a payload that was
    /// encoded before the decision to ship it as an asset was made.
    private static func dataDigest(_ data: Data) -> String {
        guard !data.isEmpty else { return absentAssetDigest }
        let hash = SHA256.hash(data: data)
        return "t:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    /// The largest encoded payload a record still carries inline in its
    /// encrypted `payload` field. CloudKit refuses a record whose fields exceed
    /// 1 MB ("record too large"); half of that leaves room for the encryption
    /// envelope and the record's other fields, and anything past it travels as
    /// a `payloadAsset`. The phone applies the same limit when it writes a
    /// ReviewSession (`MobileReviewSessionRecorder.inlinePayloadByteLimit`).
    static let inlinePayloadByteLimit = 512 * 1024

    /// Digest for an asset derived from a file on disk. Deliberately a stat
    /// signature rather than a content hash: the whole point of gating is to
    /// avoid reading a 30 MB PDF on every save, and hashing it would read it.
    /// `variant` separates fields that share a source file, so a change to one
    /// field's rendering can be invalidated without touching the other.
    /// Change detection for a file-backed asset field: has this field's content
    /// moved since CloudKit last acknowledged it?
    ///
    /// Deliberately (size, mtime, path) and not a hash of the bytes. It is the
    /// cheap, conventional test — the same one make and rsync use — and it never
    /// reads the file, which is what keeps `materializeAsset` lazy over papers up
    /// to `maxPaperPDFAssetBytes`.
    ///
    /// Know what it is not: it is not content identity. Two byte-identical files
    /// at different paths get different digests, and moving or renaming a file
    /// re-uploads it unchanged. That is a real cost — a 30 MB PDF resent because
    /// it changed folders — and the honest fix is a content hash used for asset
    /// identity while this stays the re-upload trigger.
    ///
    /// The reason not to do that yet is the switching cost, not the design. Every
    /// digest value here is stored in `sync_asset_digests.digest`, so changing how
    /// one is computed invalidates every acknowledged row at once and re-uploads
    /// the entire library. `rebaseCloudKitStateForContainerEnvironment` already
    /// pays exactly that cost on purpose, which makes the next deliberate
    /// container change — the team cutover in
    /// docs/apple-developer-account-migration.md — the moment when this fix is
    /// free. Bundling it there costs one re-upload; doing it now costs two.
    private static func fileDigest(_ path: String?, variant: String) -> String {
        guard let path, !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > 0 else {
            return absentAssetDigest
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "f:\(variant):\(size):\(modified):\(path)"
    }

    private static func makeTextAsset(
        for string: String?,
        recordName: String,
        suffix: String,
        fileExtension: String,
        digest: String
    ) throws -> CKAsset? {
        guard let string, !string.isEmpty else { return nil }
        return try materializeAsset(
            recordName: recordName,
            suffix: suffix,
            fileExtension: fileExtension,
            digest: digest
        ) { Data(string.utf8) }
    }

    /// A filesystem-safe, fixed-length name for a digest. `fileDigest` embeds an
    /// absolute path, so the digests themselves are unbounded and contain path
    /// separators; hashing the digest string — not the payload — makes a name.
    private static func assetToken(for digest: String) -> String {
        SHA256.hash(data: Data(digest.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The one place an asset becomes a file on disk, keyed by the same digest
    /// that decides whether the field needs re-uploading at all.
    ///
    /// Naming the file after its content is what makes this idempotent. The
    /// previous scheme gave every build a fresh UUID to avoid rewriting a path
    /// CloudKit might still be registering (`.assetFileModified`), but it bought
    /// that safety by never reusing anything: `attachAsset` only skips work when
    /// a digest is already *committed*, so every rebuild raised before the save
    /// was acknowledged — a retry, a failed batch, a second batch built while
    /// the first was in flight — wrote another full copy. On 2026-08-30 that had
    /// turned 8,066 asset fields into 19,305 files and 14 GB in a single day,
    /// 11 GB of it re-copied paper PDFs.
    ///
    /// Content addressing keeps the property the UUID was reaching for and drops
    /// the duplication: identical content resolves to the identical path, so an
    /// existing file is reused as-is and never rewritten. Only genuinely new
    /// content ever writes.
    ///
    /// `makeData` stays lazy so a reused asset also skips the work that would
    /// have produced its bytes — reading a PDF up to `maxPaperPDFAssetBytes`,
    /// rendering a thumbnail, inlining an EPUB chapter's images.
    private static func materializeAsset(
        recordName: String,
        suffix: String,
        fileExtension: String,
        digest: String,
        makeData: () throws -> Data?
    ) throws -> CKAsset? {
        _ = staleAssetSweep
        let directory = assetDirectory
        let fileURL = directory.appendingPathComponent(
            "\(recordName)-\(suffix)-\(assetToken(for: digest)).\(fileExtension)"
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return CKAsset(fileURL: fileURL)
        }
        guard let data = try makeData(), !data.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return CKAsset(fileURL: fileURL)
    }

    /// The `CKAsset` this field already has for this exact payload, or a freshly
    /// built one recorded for the next pass.
    ///
    /// `materializeAsset` made the *file* idempotent, and that is the whole of
    /// the on-disk problem: identical content resolves to one path and is never
    /// rewritten. It is not the whole of the upload problem. CloudKit copies
    /// every `CKAsset` it is handed into its own cache under a freshly minted
    /// asset UUID — the `<assetUUID>.<contentSignature>` files under
    /// `~/Library/Caches/CloudKit/<bundle>/<container>/Assets`. Two `CKAsset`
    /// values over one unchanged file therefore cost two full copies there,
    /// and the signatures prove it: the duplicates are byte-identical, CloudKit
    /// hashed them to the same signature, and stored them anyway. So the
    /// duplication the 2026-08-30 fix removed from the app's temp directory
    /// simply moved one layer down, into the framework's cache, where it reached
    /// 20 GB across two containers in two days.
    ///
    /// `attachAsset` only skips a field once its digest is *committed*, so any
    /// save CloudKit never acknowledged makes the next pass build again. Both
    /// unacknowledged shapes do it: an abandoned save leaves `pending_digest`
    /// set and unpromoted, and a failed save has `clearStagedAssetDigests` drop
    /// the row outright. Neither yields a committed digest, and neither means
    /// the server holds the bytes — the field genuinely must be re-attached, so
    /// the fix cannot be to skip it. What it must not do is mint a *second*
    /// asset for content already staged.
    ///
    /// Keying on the digest rather than on commit state covers both shapes with
    /// one rule — the same field asking for the same payload again gets the
    /// asset it already has — and states the invariant at the attach boundary:
    /// one payload staged for one field is one `CKAsset` for as long as this
    /// process runs. Note the bound that leaves: a relaunch starts empty, so a
    /// re-staged payload can still cost one copy per launch, not one per pass.
    /// The lower bound of one-copy-ever needs identity in the bytes, which
    /// `fileDigest` does not carry.
    private static func stagedAsset(
        recordName: String,
        field: CKRecord.FieldKey,
        digest: String,
        build: (String) throws -> CKAsset?
    ) rethrows -> CKAsset? {
        let key = StagedAssetKey(recordName: recordName, field: field, digest: digest)
        if let reused = stagedAssets.reusableAsset(for: key) { return reused.asset }
        let built = try build(digest)
        stagedAssets.record(StagedAssetBuild(asset: built), for: key)
        return built
    }

    private struct StagedAssetKey: Hashable {
        let recordName: String
        let field: String
        let digest: String
    }

    /// A build's outcome, including the deliberate absence of an asset: a field
    /// whose payload is empty, missing, or over the upload cap answers `nil`,
    /// and re-deriving that answer costs the same stat or read every time.
    private struct StagedAssetBuild {
        let asset: CKAsset?
    }

    /// Process-lifetime, bounded, and self-invalidating. Entries are tiny — a
    /// `CKAsset` is a wrapper around a file URL — so the cap exists to keep an
    /// all-day session from growing a map, not to reclaim meaningful memory.
    private static let stagedAssets = StagedAssetCache()

    private final class StagedAssetCache: @unchecked Sendable {
        /// Comfortably more than one library-wide pass over the asset fields of
        /// the records a single send window can carry.
        private static let limit = 2048

        private let lock = NSLock()
        private var builds: [StagedAssetKey: StagedAssetBuild] = [:]
        private var insertionOrder: [StagedAssetKey] = []

        /// `staleAssetSweep` deletes staged files a day old, and a reused
        /// `CKAsset` pointing at a swept path would upload nothing. Re-check the
        /// file rather than trusting the map; a miss costs one rebuild.
        func reusableAsset(for key: StagedAssetKey) -> StagedAssetBuild? {
            lock.lock()
            defer { lock.unlock() }
            guard let build = builds[key] else { return nil }
            if let url = build.asset?.fileURL,
               !FileManager.default.isReadableFile(atPath: url.path) {
                builds.removeValue(forKey: key)
                insertionOrder.removeAll { $0 == key }
                return nil
            }
            return build
        }

        func record(_ build: StagedAssetBuild, for key: StagedAssetKey) {
            lock.lock()
            defer { lock.unlock() }
            if builds.updateValue(build, forKey: key) == nil {
                insertionOrder.append(key)
            }
            while insertionOrder.count > Self.limit {
                builds.removeValue(forKey: insertionOrder.removeFirst())
            }
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            builds.removeAll()
            insertionOrder.removeAll()
        }
    }

    /// Test seam: the cache is process-wide by design, so a test that counts
    /// builds must start from a known empty state.
    static func resetStagedAssetCacheForTesting() {
        stagedAssets.removeAll()
    }

    /// Papers and PDF-backed book chapters ship their original document so iOS
    /// can pull it on demand (MobileSourceFileStore.fetchPDF), bounded so one
    /// oversized scan cannot bloat every sync. Courses stay Mac-local.
    /// Best-effort: a missing or oversized PDF simply leaves the field empty,
    /// exactly the pre-existing state of the world.
    ///
    /// Runs on the sync engine's background path (never a render path), so the
    /// caller's resolvedPDFPath stat and the file read here are safe.
    ///
    /// The cap was 30 MB while this asset was a convenience feed for iOS, where
    /// skipping a huge PDF just meant the phone fell back to a citation card.
    /// Now that content is local and this asset is how a document reaches another
    /// Mac at all, anything above the cap is a paper that silently never arrives.
    /// 23 of the 495 papers in this library are over 30 MB and the largest is
    /// 83 MB, so the cap is the transport's real floor, not a tuning knob —
    /// 128 MB covers the whole library with room to spare and stays far inside
    /// what a CKAsset carries comfortably. `ICloudStorageUsage` counts a PDF
    /// against the same cap, because one past it never reaches iCloud.
    static let maxPaperPDFAssetBytes = 128 * 1024 * 1024

    private static func makeSourcePDFAsset(path: String?, recordName: String, digest: String) -> CKAsset? {
        guard let path else { return nil }
        return try? materializeAsset(
            recordName: recordName,
            suffix: "paper-pdf",
            fileExtension: "pdf",
            digest: digest
        ) {
            let url = URL(fileURLWithPath: path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil,
                  size > 0, size <= maxPaperPDFAssetBytes else {
                return nil
            }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /// A small first-page JPEG for iOS source lists. Keeping this separate from
    /// `sourcePDFAsset` means a scrolling list never downloads the original PDF
    /// just to paint a 36 x 48 point row thumbnail.
    ///
    /// PDFKit work runs on the sync engine actor, not the main actor. Best-effort:
    /// a missing, evicted, or malformed local PDF leaves the asset empty and iOS
    /// retains its citation-card fallback.
    private static let maxPaperThumbnailPixelSize: CGFloat = 512

    private static func makePaperThumbnailAsset(
        for article: StudioArticle,
        recordName: String,
        digest: String
    ) -> CKAsset? {
        try? materializeAsset(
            recordName: recordName,
            suffix: "paper-thumbnail",
            fileExtension: "jpg",
            digest: digest
        ) { paperThumbnailJPEG(for: article) }
    }

    private static func paperThumbnailJPEG(for article: StudioArticle) -> Data? {
        guard article.sourceType == .paper,
              let path = article.resolvedPDFPath,
              let document = PDFDocument(url: URL(fileURLWithPath: path)),
              let page = document.page(at: 0) else {
            return nil
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(
            maxPaperThumbnailPixelSize / bounds.width,
            maxPaperThumbnailPixelSize / bounds.height
        )
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return jpeg as Data
    }

    /// Markup rebuilt as one self-contained HTML document, so another device
    /// reads an EPUB chapter or archived article with its real figures instead
    /// of text with every `<img>` stripped out. Images travel as `data:` URIs;
    /// nothing in the document points anywhere else.
    ///
    /// Best-effort like the paper PDF: a chapter file that is missing, evicted,
    /// or not markup leaves the field nil and iOS keeps its plain-text reader.
    /// ImageIO and file reads run on the sync engine's background path.
    private static func makeReaderHTMLAsset(
        markupPath: String?,
        recordName: String,
        digest: String
    ) -> CKAsset? {
        guard let markupPath else { return nil }
        return try? materializeAsset(
            recordName: recordName,
            suffix: "reader-html",
            fileExtension: "html",
            digest: digest
        ) {
            guard let document = EPUBParser.readerDocument(forMarkupAt: markupPath),
                  !document.html.isEmpty else {
                return nil
            }
            return Data(document.html.utf8)
        }
    }

    /// Book covers ship as a small JPEG asset so the phone's book lists can show
    /// the same cover the Mac renders, without the book files. Downscaled with
    /// ImageIO — cover.jpg can be print resolution, and no row renders past
    /// ~60pt. Best-effort like the paper PDF: a cover whose bytes are not on
    /// this Mac leaves the server's asset exactly as it is.
    private static let maxBookCoverPixelSize = 512

    /// The book cover's readable file on this Mac, or nil when the bytes are
    /// somewhere this device cannot see.
    ///
    /// `books.cover_path` is stored relative to the ForeverLM content root (like
    /// `localFilePath` elsewhere), so it must be resolved before any stat — a
    /// bare "Books/Foo/cover.jpg" checked against the process's cwd is why no
    /// cover ever uploaded. Every known root is searched, not just the current
    /// one: a cover written under the old ubiquity container is still the cover,
    /// which is the same reason library rows resolve covers multi-root.
    static func readableBookCoverPath(_ coverPath: String?) -> String? {
        guard let coverPath, !coverPath.isEmpty else { return nil }
        let absolutePath = StorageService.absoluteSourcePath(coverPath)
        // `locateSourceFile` also matches an undownloaded iCloud placeholder;
        // only a file whose bytes are here can be read into an asset.
        let candidate = StorageService.locateSourceFile(absolutePath) ?? absolutePath
        return FileManager.default.isReadableFile(atPath: candidate) ? candidate : nil
    }

    private static func makeBookCoverAsset(
        absolutePath: String,
        recordName: String,
        digest: String
    ) -> CKAsset? {
        try? materializeAsset(
            recordName: recordName,
            suffix: "book-cover",
            fileExtension: "jpg",
            digest: digest
        ) { bookCoverJPEG(absolutePath: absolutePath) }
    }

    private static func bookCoverJPEG(absolutePath: String) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: absolutePath) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxBookCoverPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return jpeg as Data
    }

    /// Whether this source's artwork is a meeting icon this app wrote, rather
    /// than a podcast cover or YouTube still sitting at an `https://` URL that
    /// every device can already fetch for itself.
    static func recordsLocalMeetingIcon(_ article: StudioArticle) -> Bool {
        article.sourceType == .meeting
            && MeetingIconService.localArtworkPath(for: article.artworkURL) != nil
    }

    /// The meeting icon's readable file on this Mac, or nil when the bytes are
    /// somewhere this device cannot see.
    ///
    /// Current content root only — deliberately narrower than
    /// `readableBookCoverPath`. Book covers genuinely predate the move to local
    /// storage and can still sit under an old root; meeting icons are written by
    /// one service that has only ever resolved them one way, and matching it
    /// keeps "this Mac has the icon" a single answer for the uploader, the
    /// backfill count, and the row that draws it.
    static func readableMeetingIconPath(for article: StudioArticle) -> String? {
        guard recordsLocalMeetingIcon(article),
              let absolutePath = MeetingIconService.localArtworkPath(for: article.artworkURL) else {
            return nil
        }
        return FileManager.default.isReadableFile(atPath: absolutePath) ? absolutePath : nil
    }

    /// Meeting icons ship as written rather than downscaled the way book covers
    /// are: `MeetingIconService` already stores them square at 256 pixels, a few
    /// kilobytes each. The bound is a sanity check, not a budget — anything that
    /// large at this path is not an icon this app made.
    private static let maxMeetingIconAssetBytes = 2 * 1024 * 1024

    private static func makeMeetingIconAsset(
        absolutePath: String,
        recordName: String,
        digest: String
    ) -> CKAsset? {
        try? materializeAsset(
            recordName: recordName,
            suffix: "meeting-icon",
            fileExtension: "jpg",
            digest: digest
        ) {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: absolutePath)[.size] as? Int) ?? nil,
                  size > 0, size <= maxMeetingIconAssetBytes else {
                return nil
            }
            return try? Data(contentsOf: URL(fileURLWithPath: absolutePath), options: .mappedIfSafe)
        }
    }

    private static func makeCourseQuizPicturesAsset(
        files: [CourseQuizPicturePackage.File],
        recordName: String,
        digest: String
    ) -> CKAsset? {
        try? materializeAsset(
            recordName: recordName,
            suffix: "quiz-pictures",
            fileExtension: "plist",
            digest: digest
        ) { CourseQuizPicturePackage.encode(files) }
    }

    private static func makeWalkthroughPicturesAsset(
        _ pictures: WalkthroughPicturePackage.Contents,
        recordName: String,
        digest: String
    ) -> CKAsset? {
        try? materializeAsset(
            recordName: recordName,
            suffix: "walkthrough-pictures",
            fileExtension: "plist",
            digest: digest
        ) { pictures.encoded() }
    }

    private static var assetDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ForeverLMRuntimeIdentity.productFolderName)-CloudKitAssets",
                isDirectory: true
            )
    }

    // Asset files now accumulate only as content genuinely changes — a rebuild of
    // unchanged content reuses its file rather than adding one — but a library that
    // keeps being edited still grows this directory without bound. Sweep files old
    // enough that no CKSyncEngine upload can still reference them; sweeping one that
    // is still current costs a single rewrite on the next build, not a lost asset.
    // Runs once per process, off-main.
    private static let staleAssetSweep: Void = {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? fileManager.contentsOfDirectory(
            at: assetDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }()

    private static func loadAssetString(from asset: CKAsset?) -> String? {
        guard let url = asset?.fileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

}

extension CKRecord.FieldKey {
    static let payload = "payload"
    /// The record's payload as a CKAsset instead of inline bytes. Every Article
    /// body travels this way; a ReviewSession does only when its encoded
    /// payload exceeds `inlinePayloadByteLimit`. CloudKit schema is per record
    /// type, so each type that writes this field needs it promoted separately.
    static let payloadAsset = "payloadAsset"
    static let userModificationDate = "userModificationDate"
    static let sourceContentAsset = "sourceContentAsset"
    /// Prepared text consumed by Listen. Metadata in the encrypted payload binds
    /// this asset to the canonical source-content hash.
    static let sourceListenableContentAsset = "sourceListenableContentAsset"
    /// Original paper extraction. It is never exposed as ordinary source text;
    /// it exists so cleanup can be audited or rerun without reopening the PDF.
    static let sourceRawContentAsset = "sourceRawContentAsset"
    static let podcastRawTTMLAsset = "podcastRawTTMLAsset"
    /// Original paper PDF, uploaded so iOS can pull the document on demand.
    /// NOTE: a new record field — run a Development-environment build once so
    /// CloudKit creates it, then deploy the schema to Production before any
    /// production build syncs, or Source saves will fail with invalid field.
    static let sourcePDFAsset = "sourcePDFAsset"
    /// First-page paper JPEG used by iOS source rows without fetching the PDF.
    /// NOTE: create this field in Development, then deploy it to Production
    /// before shipping the corresponding Mac build.
    static let paperThumbnailAsset = "paperThumbnailAsset"
    /// Downscaled book cover JPEG, uploaded so the phone's book lists show real
    /// covers on demand. Same schema NOTE as `sourcePDFAsset`: Development
    /// build once, then deploy to Production before production builds sync.
    static let bookCoverAsset = "bookCoverAsset"
    /// A meeting's captured or drawn icon, uploaded because it has no other
    /// transport: the JPEG used to ride the ubiquity container as ordinary
    /// source content, and content went local on 2026-08-18. Same schema NOTE
    /// as `sourcePDFAsset`: Development build once, then deploy to Production
    /// before production builds sync a meeting that has an icon.
    static let meetingIconAsset = "meetingIconAsset"
    /// Self-contained reader HTML for sources whose images live in files the
    /// phone does not have — today EPUB-backed book chapters, with their figures
    /// inlined as `data:` URIs. Named for the shape rather than for books so
    /// archived web articles can reuse it without another schema field.
    /// Same schema NOTE as `sourcePDFAsset`: Development build once, then deploy
    /// to Production before production builds sync.
    static let sourceReaderHTMLAsset = "sourceReaderHTMLAsset"
    /// The pictures a course's quizzes show from the image store, packed as
    /// one binary property list on the Course record
    /// (`CourseQuizPicturePackage`). Same schema NOTE as `sourcePDFAsset`:
    /// Development build once, then deploy to Production before production
    /// builds sync a course whose quizzes show a drawn or saved picture.
    static let courseQuizPicturesAsset = "courseQuizPicturesAsset"
    /// The drawn pictures a source's walk shows, packed as one binary
    /// property list on the Source record (`WalkthroughPicturePackage`,
    /// `WalkthroughPicturePackageFormat.field`). Same schema NOTE as
    /// `sourcePDFAsset`: Development build once, then deploy to Production
    /// before production builds sync a source whose walk shows a drawn picture.
    static let walkthroughPicturesAsset = WalkthroughPicturePackageFormat.field
}

/// Pictures from this Mac's image store packed into one CloudKit asset beside
/// the record that shows them: a course's quizzes (`CourseQuizPicturePackage`,
/// on the Course record) or a source's walk (`WalkthroughPicturePackage`, on
/// the Source record).
///
/// A drawn or saved picture lives only in the store of the Mac that holds it
/// (`GeneratedImageStore`), and the record that names it rides to every other
/// Mac. So the bytes go beside the payload, as a binary property list of file
/// name → file bytes: each file exactly as stored, its prompt, title and
/// version in its own XMP, so the receiving Mac's store holds the same picture
/// under the same id, and whatever names `foreverlm://image/generated/<id>`
/// shows it there as it does here. A receiving Mac only ever adds pictures;
/// the one thing it writes to a picture it already holds is the mark that a
/// redraw it just received replaces it (`GeneratedImageStore.adoptArrivedRedraw`),
/// pixels untouched.
enum StoredPicturePackage {
    /// A picture larger than this is left out: no image model returns one,
    /// and a file that size is not a picture for a quiz question or a card.
    static let maximumPictureBytes = 16 * 1024 * 1024
    /// The package stops growing here; the pictures past it stay on the Macs
    /// that hold them.
    static let maximumPackageBytes = 64 * 1024 * 1024

    struct File: Equatable, Sendable {
        let id: String
        let path: String
        let size: Int
        let modified: TimeInterval

        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    static let storedExtensions = ["png", "jpg", "webp"]

    /// The files this Mac holds for `ids`, in that order, within the caps. A
    /// picture this Mac does not hold — never received, or deleted by the
    /// learner — is left out, and the rest still travel. Stats only; reads
    /// no bytes.
    static func localFiles(for ids: [String], root: URL? = nil) -> [File] {
        var files: [File] = []
        var total = 0
        for id in ids {
            guard let path = storedPath(id: id, root: root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > 0, size <= maximumPictureBytes, total + size <= maximumPackageBytes else { continue }
            total += size
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            files.append(File(id: id, path: path, size: size, modified: modified))
        }
        return files
    }

    /// The field's change signature: which pictures, at what size and date,
    /// and whatever else `extra` says travels with them, hashed so the stored
    /// digest stays short however many there are.
    static func digest(_ files: [File], prefix: String, extra: String = "") -> String {
        var signature = files.map { "\($0.name):\($0.size):\($0.modified)" }.joined(separator: "|")
        if !extra.isEmpty { signature += "#" + extra }
        return prefix + SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The package's bytes: a binary property list of file name → bytes,
    /// with `extraEntries` beside them. Nil when none of the files can be read.
    static func encode(_ files: [File], extraEntries: [String: Data] = [:]) -> Data? {
        var entries: [String: Data] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe),
                  !data.isEmpty else { continue }
            entries[file.name] = data
        }
        guard !entries.isEmpty else { return nil }
        entries.merge(extraEntries) { stored, _ in stored }
        return try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    /// Writes each picture of an arriving package into this Mac's image store
    /// (under `root`, the content root by default) when the store does not
    /// hold it yet, and returns the ids written. A name that is not a store
    /// file name, or bytes that are not an image, are skipped, and nothing
    /// already in the store is replaced or removed. `kind` names the record
    /// in a failure's log line. Reads and writes files: the sync engine's
    /// background path, never a render one.
    @discardableResult
    static func materialize(packageAt url: URL, root: URL?, kind: String) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumPackageBytes + 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let entries = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Data] else {
            return []
        }
        let folder = directory(root)
        var written: [String] = []
        for (name, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            let file = URL(fileURLWithPath: name)
            let id = file.deletingPathExtension().lastPathComponent
            let fileExtension = file.pathExtension
            guard name == "\(id).\(fileExtension)",
                  GeneratedImageReference.isValidID(id), storedExtensions.contains(fileExtension),
                  !bytes.isEmpty, bytes.count <= maximumPictureBytes,
                  storedPath(id: id, root: root) == nil,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { continue }
            let staging = folder.appendingPathComponent(".\(UUID().uuidString).incoming", isDirectory: false)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                try bytes.write(to: staging, options: .atomic)
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                try FileManager.default.moveItem(at: staging, to: destination)
                written.append(id)
                // A picture redrawn on the other Mac replaces, here too, the
                // version it was drawn over, so an old line or card shows it.
                GeneratedImageStore.adoptArrivedRedraw(id: id, fileAt: destination, in: folder)
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CloudKitSync").warning(
                    "Inbound \(kind, privacy: .public) picture \(id, privacy: .public) could not be stored: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return written
    }

    /// Tells what shows a stored picture that `ids` just arrived: each id
    /// and its image's, so a walkthrough card naming either reads the store
    /// again (`WalkthroughCardDrawnPicture`). Reads each arrival's metadata.
    static func announceArrival(of ids: [String], root: URL?) {
        guard !ids.isEmpty else { return }
        var named = Set(ids)
        for id in ids {
            guard let path = storedPath(id: id, root: root),
                  let imageID = GeneratedImageStore.details(ofFileAt: URL(fileURLWithPath: path))?.imageID else { continue }
            named.insert(imageID)
        }
        let arrived = named.sorted()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .generatedImagesArrived,
                object: nil,
                userInfo: [GeneratedImageStore.changedIDsKey: arrived]
            )
        }
    }

    static func storedPath(id: String, root: URL?) -> String? {
        let folder = directory(root)
        for fileExtension in storedExtensions {
            let path = folder.appendingPathComponent("\(id).\(fileExtension)", isDirectory: false).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func directory(_ root: URL?) -> URL {
        (root ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true))
            .appendingPathComponent(GeneratedImageStore.directory, isDirectory: true)
    }
}

/// The pictures a course's quizzes show from this Mac's image store, packed
/// into one CloudKit asset on the course's record (`courseQuizPicturesAsset`,
/// `StoredPicturePackage`). A quiz rides the Course record, whose payload
/// already carries every quiz of the course inside CloudKit's 1 MB record
/// limit, so the pictures go beside it.
enum CourseQuizPicturePackage {
    typealias File = StoredPicturePackage.File

    // MARK: Holding uploads while a course's pictures are drawn

    private static let holdLock = NSLock()
    nonisolated(unsafe) private static var holds: [String: Int] = [:]

    /// Leaves the course's package off every record sent until
    /// `releaseUploads`: a drawing run pins its pictures one by one, and a
    /// course with a picture on every question would otherwise upload its
    /// whole package again with each. Counted, so two runs on one course
    /// release it only when both are done. In memory only: a Mac that quits
    /// mid-run holds nothing on its next launch, and its next save uploads.
    static func holdUploads(courseID: String) {
        holdLock.lock(); defer { holdLock.unlock() }
        holds[courseID, default: 0] += 1
    }

    static func releaseUploads(courseID: String) {
        holdLock.lock(); defer { holdLock.unlock() }
        let remaining = (holds[courseID] ?? 1) - 1
        holds[courseID] = remaining > 0 ? remaining : nil
    }

    static func isHoldingUploads(courseID: String) -> Bool {
        holdLock.lock(); defer { holdLock.unlock() }
        return holds[courseID] != nil
    }

    /// The store's version ids the quizzes' pictures show, in quiz order, each once.
    static func storedImageIDs(in quizzes: [CourseQuiz]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for quiz in quizzes {
            for question in quiz.questions {
                if let id = question.picture?.storedImageID, seen.insert(id).inserted { ids.append(id) }
            }
        }
        return ids
    }

    static func localFiles(for ids: [String], root: URL? = nil) -> [File] {
        StoredPicturePackage.localFiles(for: ids, root: root)
    }

    static func digest(_ files: [File]) -> String {
        StoredPicturePackage.digest(files, prefix: "q:")
    }

    static func encode(_ files: [File]) -> Data? {
        StoredPicturePackage.encode(files)
    }

    @discardableResult
    static func materialize(packageAt url: URL, root: URL?) -> [String] {
        StoredPicturePackage.materialize(packageAt: url, root: root, kind: "quiz")
    }

    static func storedPath(id: String, root: URL?) -> String? {
        StoredPicturePackage.storedPath(id: id, root: root)
    }
}

/// The drawn pictures a source's walk shows, packed into one CloudKit asset
/// on the Source record (`walkthroughPicturesAsset`; the format is
/// `WalkthroughPicturePackageFormat`).
///
/// A step names a picture of this Mac's image store by id
/// (`PaperWalkthroughPicture.imageID`): one the walk's writer drew, one drawn
/// with `generate_image`, or one made elsewhere and kept with `save_image`.
/// The walk rides the Source record's payload to the learner's other Macs and
/// the phone; until 2026-09-30 its pictures did not, so a walk saved on one
/// Mac dealt bare cards on every other device. Each image a step names now
/// travels whole — every version, the one a step shows first, so the cap
/// drops a version nothing shows before one a card does — and the receiving
/// Mac's store shows what this one does from the files' own XMP: the image's
/// latest when a step names the image, a version as redrawn when it names
/// that version (`GeneratedImageStore.readImageOrVersion`). The manifest says
/// the same for the phone, which keeps no image store.
enum WalkthroughPicturePackage {
    struct Contents: Equatable, Sendable {
        /// The files packed, the versions steps show first.
        let files: [StoredPicturePackage.File]
        /// Each id a step names → the file name shown for it, for every id
        /// whose file is packed.
        let shown: [String: String]

        var isEmpty: Bool { files.isEmpty }

        /// Changes when a file does or when what a step shows does.
        var digest: String {
            StoredPicturePackage.digest(
                files,
                prefix: "w:",
                extra: shown.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            )
        }

        /// The package's bytes, the manifest beside the files.
        func encoded() -> Data? {
            guard let manifest = try? PropertyListSerialization.data(fromPropertyList: shown, format: .binary, options: 0) else {
                return nil
            }
            return StoredPicturePackage.encode(files, extraEntries: [WalkthroughPicturePackageFormat.manifestName: manifest])
        }
    }

    /// What the Source record carries for the pictures `ids` names (a walk's
    /// `drawnPictureIDs`), from the store under `root` (the content root by
    /// default). An id this Mac holds nothing for is left out, and the rest
    /// still travel. Reads each stored file's metadata, not its pixels;
    /// never called on the main actor.
    static func contents(for ids: [String], root: URL? = nil) -> Contents {
        let wanted = ids.map { $0.lowercased() }.filter(GeneratedImageReference.isValidID)
        guard !wanted.isEmpty else { return Contents(files: [], shown: [:]) }
        let groups = GeneratedImageStore.groups(GeneratedImageStore.list(in: StoredPicturePackage.directory(root)))
        var shownFile: [String: String] = [:]
        var shownIDs: [String] = []
        var otherIDs: [String] = []
        for id in wanted {
            guard let group = groups.first(where: { $0.imageID == id })
                ?? groups.first(where: { group in group.versions.contains { $0.id == id } }) else { continue }
            let version = id == group.imageID ? group.latest : group.shown(for: id)
            shownFile[id] = URL(fileURLWithPath: version.path).lastPathComponent
            shownIDs.append(version.id)
            otherIDs.append(contentsOf: group.versions.map(\.id))
        }
        var seen = Set<String>()
        let ordered = (shownIDs + otherIDs).filter { seen.insert($0).inserted }
        let files = StoredPicturePackage.localFiles(for: ordered, root: root)
        let packed = Set(files.map(\.name))
        return Contents(files: files, shown: shownFile.filter { packed.contains($0.value) })
    }

    /// Writes an arriving package's pictures into this Mac's store; the
    /// manifest is not a store file name and is passed over.
    @discardableResult
    static func materialize(packageAt url: URL, root: URL?) -> [String] {
        StoredPicturePackage.materialize(packageAt: url, root: root, kind: "walkthrough")
    }
}

enum CloudKitSyncError: LocalizedError {
    case missingPayload(String)
    case unsupportedRecordType(String)
    case immutableRecordConflict(entity: String, logicalKey: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingPayload(let recordName):
            return "Missing CloudKit payload for record \(recordName)"
        case .unsupportedRecordType(let recordType):
            return "Unsupported CloudKit record type \(recordType)"
        case .immutableRecordConflict(let entity, let logicalKey, let detail):
            return "CloudKit immutable conflict for \(entity) \(logicalKey): \(detail)"
        }
    }
}
