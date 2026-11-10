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

struct CloudKitSourceIdentityPayload: Codable, Sendable {
    let sourceID: String
    let url: String?
    let normalizedURL: String?
    let doi: String?
    let publishedDOI: String?
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

// CloudKitAIUsageEventPayload lives in AIUsageReporting.swift so the mobile
// targets encode the exact same payload shape when authoring usage records.

enum CloudKitRecordMapper {
    static func recordName(for entity: CloudKitSyncEntity, logicalKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(entity.rawValue):\(logicalKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    static func bookCoverJPEG(absolutePath: String) -> Data? {
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

}

extension CKRecord.FieldKey {
    static let payload = "payload"
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

