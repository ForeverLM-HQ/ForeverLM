import Foundation

/// `Chat.kind` (§3.5.13): `review`, `memory`, `quizSitting`, `walkthrough` and `voice` are private
/// and stay in the member's `Library` even when filed in a space notebook (D19).
enum ChatKind: String, CaseIterable, Sendable {
    case chat
    case review
    case memory
    case quizSitting
    case walkthrough
    case voice
    case transcript

    var isPrivate: Bool {
        !(SyncRecordType.chat.spec.spaceRule?.allowedValues.contains(rawValue) ?? false)
    }
}

/// The kind of a chat recorded before generation 2 wrote kinds (D50, §10): 299 of the library's
/// chats predate the `kind` column, and a voice session, a walkthrough's chat, a course quiz's
/// sitting or a scored review among them must not become a shareable `chat`. One ordered rule set,
/// used by the generation-2 activation and, through
/// the JS twin `schema/js/chat-kind.js`, the web's and the hosted MCP's chat writers. The caller
/// fills the evidence from what it holds, so this reads no store. Vectors:
/// `schema/vectors/chat-kind.json`.
enum ChatKindClassifier {
    /// What the rules read about one chat.
    struct Evidence: Equatable, Sendable {
        /// `review_sessions.id`.
        var id: String
        /// The generation-1 `kind` column (`chat`, `review`, `memory`); nil before schema 89.
        var kind: String?
        /// The chat is a team's snapshot copy (`team_id` set: the `teamchat-` copies of `share_with_team`).
        var isTeamSnapshot = false
        /// A walk's progress names the chat (`walkthrough_progress.progress_json.chat_session_id`).
        var isNamedByWalkthroughProgress = false
        /// An exchange carries a walkthrough step line (`WalkthroughStepTurn.marker(in:)` finds one).
        var holdsWalkthroughStep = false
        /// `overall_score` is set.
        var hasOverallScore = false
        /// The session holds card ids (a memory check's planned queue).
        var hasCardIDs = false
        /// An exchange has a score or an idea coverage.
        var hasGradedExchange = false

        init(id: String, kind: String? = nil, isTeamSnapshot: Bool = false, isNamedByWalkthroughProgress: Bool = false,
             holdsWalkthroughStep: Bool = false, hasOverallScore: Bool = false, hasCardIDs: Bool = false,
             hasGradedExchange: Bool = false) {
            self.id = id
            self.kind = kind
            self.isTeamSnapshot = isTeamSnapshot
            self.isNamedByWalkthroughProgress = isNamedByWalkthroughProgress
            self.holdsWalkthroughStep = holdsWalkthroughStep
            self.hasOverallScore = hasOverallScore
            self.hasCardIDs = hasCardIDs
            self.hasGradedExchange = hasGradedExchange
        }
    }

    /// `MemoryReviewSession.idPrefix`, and the MCP's daily reviews and their operation sessions.
    static let memoryIDPrefixes = ["memory-", "mcp-memory-review-"]
    /// `CourseQuizSitting.sessionIDPrefix`.
    static let courseQuizIDPrefix = "course-quiz-"
    /// `mac-live-`, `ios-live-`, `carplay-live-`: the realtime voice sessions retired in `76d92fe83`.
    static let liveVoiceIDMarker = "-live-"

    /// The first rule that holds, in this order.
    static func kind(of evidence: Evidence) -> ChatKind {
        if evidence.isTeamSnapshot { return .transcript }
        if evidence.kind == ChatKind.memory.rawValue || memoryIDPrefixes.contains(where: evidence.id.hasPrefix) {
            return .memory
        }
        if evidence.id.hasPrefix(courseQuizIDPrefix) { return .quizSitting }
        if evidence.id.contains(liveVoiceIDMarker) { return .voice }
        if evidence.isNamedByWalkthroughProgress || evidence.holdsWalkthroughStep { return .walkthrough }
        if evidence.kind == ChatKind.review.rawValue || evidence.hasOverallScore || evidence.hasCardIDs
            || evidence.hasGradedExchange {
            return .review
        }
        return .chat
    }
}
