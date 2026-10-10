import CloudKit
import Foundation

// MARK: - An old record, decoded (docs/cloudkit-schema-design.md §13.6, WP15c)

/// One record of the generation-1 container's `Knowledge` or `Team-*` zones, decoded with today's
/// inbound payload structs (`CloudKit*Payload`), which stay for this one release. The late import, the
/// refresh and the catch-ups read old records only through this, and map them with `LegacyV2Mapping`.
struct LegacyRecord: Sendable {
    let entity: CloudKitSyncEntity
    /// The record's logical key, as generation 1 named it (`CloudKitRecordMapper.descriptor`).
    let logicalKey: String
    let recordName: String
    /// The old zone: `Knowledge`, or a team's `Team-<id>`.
    let zoneName: String
    let changeTag: String?
    /// The server's modification date: every field the record gives is stamped with it (§13.6).
    let modifiedAt: Date
    let payload: LegacyPayload
    /// An Artifact's body package as the record carries it in `payloadAsset`; nil when the asset was
    /// not fetched (an unchanged Doc's package is never downloaded) or the record holds none.
    let bodyPackage: Data?

    /// The team whose zone holds the record; nil for the learner's own `Knowledge` zone.
    var teamID: String? { TeamRecord.teamID(fromZoneName: zoneName) }

    init(
        entity: CloudKitSyncEntity, logicalKey: String, recordName: String, zoneName: String = CloudKitZoneHome.knowledgeZoneName,
        changeTag: String? = nil, modifiedAt: Date, payload: LegacyPayload, bodyPackage: Data? = nil
    ) {
        self.entity = entity
        self.logicalKey = logicalKey
        self.recordName = recordName
        self.zoneName = zoneName
        self.changeTag = changeTag
        self.modifiedAt = modifiedAt
        self.payload = payload
        self.bodyPackage = bodyPackage
    }
}

/// An old record's payload, as today's decoders read it. A key such a payload omits stays what its
/// decoder makes of it (nil, or a `has…Payload` flag), so `LegacyV2Mapping` can tell an omission from an
/// explicit value (R6-m4).
enum LegacyPayload: Sendable {
    case source(CloudKitSourcePayload)
    case sourceHighlight(CloudKitSourceHighlightPayload)
    case book(CloudKitBookPayload)
    case course(CloudKitCoursePayload)
    case videoPlaylist(CloudKitVideoPlaylistPayload)
    case meetingGroup(CloudKitMeetingGroupPayload)
    case hiddenSource(CloudKitHiddenSourcePayload)
    case hiddenPodcastShow(CloudKitHiddenPodcastShowPayload)
    case hiddenYouTubeChannel(CloudKitHiddenYouTubeChannelPayload)
    case hiddenArtifact(CloudKitHiddenArtifactPayload)
    case hiddenReviewSession(CloudKitHiddenReviewSessionPayload)
    case dismissedSource(CloudKitDismissedSourcePayload)
    case reviewSession(CloudKitReviewSessionPayload)
    case memoryItem(CloudKitMemoryItemPayload)
    case memoryAttempt(CloudKitMemoryAttemptPayload)
    case sourceIdea(CloudKitSourceIdeaPayload)
    case memoryReviewActivity(CloudKitMemoryReviewActivityPayload)
    case learningGoal(CloudKitLearningGoalPayload)
    case artifact(CloudKitArtifactPayload)
    case artifactComment(ArtifactCommentRecord)
    case scheduledSource(CloudKitScheduledSourcePayload)
    case scheduledTask(CloudKitScheduledTaskPayload)
    case idea(CloudKitIdeaPayload)
    case walkthroughProgress(CloudKitWalkthroughProgressPayload)
    case skill(CloudKitSkillPayload)
    case researchDirection(CloudKitResearchDirectionPayload)
    case videoCitedPaper(CloudKitVideoCitedPaperPayload)
    case preference(CloudKitPreferencePayload)
    case team(CloudKitTeamPayload)
    case notebookTask(CloudKitNotebookTaskPayload)
    case shareRequest(CloudKitShareRequestPayload)
    /// A type §10 drops (`ChatContext`, `DayPlan`, `ResearchCanvas`, `AIUsageEvent`): decoded no further.
    case dropped
}

enum LegacyRecordDecoderError: Error, Equatable {
    case unsupportedRecordType(String)
    case missingPayload(String)
}

/// Reads an old record (§13.6 "Payload wherever it travels"): its payload from `payload` or, for a
/// chat over 512 KiB, from `payloadAsset` (today's `payloadData(from:)`), and an Artifact's body
/// package from `payloadAsset`, the only place the web writes it. `payloadAsset` is payload in every
/// old-world reader, never file bytes; only the source file assets are left to the asset pass.
enum LegacyRecordDecoder {
    static func decode(_ record: CKRecord) throws -> LegacyRecord {
        guard let entity = CloudKitSyncEntity.from(recordType: record.recordType) else {
            throw LegacyRecordDecoderError.unsupportedRecordType(record.recordType)
        }
        let recordName = record.recordID.recordName
        guard let data = CloudKitRecordMapper.encodedPayloadData(from: record) else {
            throw LegacyRecordDecoderError.missingPayload(recordName)
        }
        let payload = try decodePayload(entity, data)
        let logicalKey = try CloudKitRecordMapper.descriptor(for: record).logicalKey
        var bodyPackage: Data?
        if entity == .artifact, let asset = record[.payloadAsset] as? CKAsset, let url = asset.fileURL {
            bodyPackage = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        return LegacyRecord(
            entity: entity, logicalKey: logicalKey, recordName: recordName, zoneName: record.recordID.zoneID.zoneName,
            changeTag: record.recordChangeTag, modifiedAt: record.modificationDate ?? Date(timeIntervalSince1970: 0),
            payload: payload, bodyPackage: bodyPackage
        )
    }

    /// An old record's payload bytes as its type's decoder reads them.
    static func decodePayload(_ entity: CloudKitSyncEntity, _ data: Data) throws -> LegacyPayload {
        let decoder = JSONDecoder()
        func read<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type, from: data) }
        switch entity {
        case .source: return .source(try read(CloudKitSourcePayload.self))
        case .sourceHighlight: return .sourceHighlight(try read(CloudKitSourceHighlightPayload.self))
        case .book: return .book(try read(CloudKitBookPayload.self))
        case .course: return .course(try read(CloudKitCoursePayload.self))
        case .videoPlaylist: return .videoPlaylist(try read(CloudKitVideoPlaylistPayload.self))
        case .meetingGroup: return .meetingGroup(try read(CloudKitMeetingGroupPayload.self))
        case .hiddenSource: return .hiddenSource(try read(CloudKitHiddenSourcePayload.self))
        case .hiddenPodcastShow: return .hiddenPodcastShow(try read(CloudKitHiddenPodcastShowPayload.self))
        case .hiddenYouTubeChannel: return .hiddenYouTubeChannel(try read(CloudKitHiddenYouTubeChannelPayload.self))
        case .hiddenArtifact: return .hiddenArtifact(try read(CloudKitHiddenArtifactPayload.self))
        case .hiddenReviewSession: return .hiddenReviewSession(try read(CloudKitHiddenReviewSessionPayload.self))
        case .dismissedSource: return .dismissedSource(try read(CloudKitDismissedSourcePayload.self))
        case .reviewSession: return .reviewSession(try read(CloudKitReviewSessionPayload.self))
        case .memoryItem: return .memoryItem(try read(CloudKitMemoryItemPayload.self))
        case .memoryAttempt: return .memoryAttempt(try read(CloudKitMemoryAttemptPayload.self))
        case .sourceIdea: return .sourceIdea(try read(CloudKitSourceIdeaPayload.self))
        case .memoryReviewActivity: return .memoryReviewActivity(try read(CloudKitMemoryReviewActivityPayload.self))
        case .learningGoal: return .learningGoal(try read(CloudKitLearningGoalPayload.self))
        case .artifact: return .artifact(try read(CloudKitArtifactPayload.self))
        case .artifactComment: return .artifactComment(try read(ArtifactCommentRecord.self))
        case .scheduledSource: return .scheduledSource(try read(CloudKitScheduledSourcePayload.self))
        case .scheduledTask: return .scheduledTask(try read(CloudKitScheduledTaskPayload.self))
        case .idea: return .idea(try read(CloudKitIdeaPayload.self))
        case .walkthroughProgress: return .walkthroughProgress(try read(CloudKitWalkthroughProgressPayload.self))
        case .skill: return .skill(try read(CloudKitSkillPayload.self))
        case .researchDirection: return .researchDirection(try read(CloudKitResearchDirectionPayload.self))
        case .videoCitedPaper: return .videoCitedPaper(try read(CloudKitVideoCitedPaperPayload.self))
        case .preference: return .preference(try read(CloudKitPreferencePayload.self))
        case .team: return .team(try read(CloudKitTeamPayload.self))
        case .notebookTask: return .notebookTask(try read(CloudKitNotebookTaskPayload.self))
        case .shareRequest: return .shareRequest(try read(CloudKitShareRequestPayload.self))
        case .chatContext, .dayPlan, .researchCanvas, .aiUsageEvent: return .dropped
        }
    }
}
