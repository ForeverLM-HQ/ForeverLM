import Foundation
import Testing
@testable import ForeverLM

/// The kinds of chats recorded before generation 2 wrote them (D50, §10): one ordered rule set, so a
/// voice session, a walk's chat, a quiz sitting or a scored review never travels into a space as a
/// shareable `chat`. The shapes are the production library's.
@Suite("Chat kind classifier")
struct ChatKindClassifierTests {
    typealias Evidence = ChatKindClassifier.Evidence
    static let uuid = "6F1C0E8A-0B8D-4D5C-9F5E-3F0E1C2B9A77"

    @Test("The chat-kind vectors hold")
    func vectors() {
        SyncVectorRunner.expectCases("chat-kind")
    }

    @Test("The kinds are the schema's ChatKind values, and the private ones are those the space rule refuses")
    func kindsMatchTheSchema() {
        #expect(ChatKind.allCases.map(\.rawValue) == SyncSchema.enums["ChatKind"])
        #expect(Set(ChatKind.allCases.filter(\.isPrivate)) == [.review, .memory, .quizSitting, .walkthrough, .voice])
    }

    @Test("A NULL-kind ios-live- session is voice")
    func liveSession() {
        #expect(ChatKindClassifier.kind(of: Evidence(id: "ios-live-\(Self.uuid)")) == .voice)
        #expect(ChatKindClassifier.kind(of: Evidence(id: "carplay-live-\(Self.uuid)")) == .voice)
    }

    @Test("A course-quiz- chat is a quiz sitting, the prefix CourseQuizSitting mints")
    func courseQuiz() {
        let id = CourseQuizSitting.sessionIDPrefix + "cq-0123456789abcdef0123456789abcdef-" + Self.uuid
        #expect(ChatKindClassifier.kind(of: Evidence(id: id)) == .quizSitting)
        #expect(ChatKindClassifier.courseQuizIDPrefix == CourseQuizSitting.sessionIDPrefix)
    }

    @Test("A walkthrough's chat, named by a walk's progress or holding a step line")
    func walkthrough() {
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, isNamedByWalkthroughProgress: true)) == .walkthrough)
        let stepLine = WalkthroughStepTurn.line(WalkthroughStepTurn.Marker(sourceID: "src_1", stepID: "s2", index: 1, count: 6))
        let holdsStep = WalkthroughStepTurn.marker(in: stepLine + "\nWhat does the membrane potential do here?") != nil
        #expect(holdsStep)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, holdsWalkthroughStep: holdsStep)) == .walkthrough)
    }

    @Test("A scored review recorded before kinds is a review; so is one with card ids or a graded exchange")
    func scoredReview() {
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, hasOverallScore: true)) == .review)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, hasCardIDs: true)) == .review)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, hasGradedExchange: true)) == .review)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, kind: "review")) == .review)
    }

    @Test("The MCP's memory reviews and their operation sessions are memory, and so is MemoryReviewSession's prefix")
    func memory() {
        #expect(ChatKindClassifier.kind(of: Evidence(id: "mcp-memory-review-operation-\(Self.uuid)")) == .memory)
        #expect(ChatKindClassifier.kind(of: Evidence(id: MemoryReviewSession.idPrefix + Self.uuid)) == .memory)
        #expect(ChatKindClassifier.memoryIDPrefixes.contains(MemoryReviewSession.idPrefix))
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, kind: "memory")) == .memory)
    }

    @Test("A team snapshot is a transcript, whatever else it holds")
    func teamSnapshot() {
        let id = TeamContentIdentity.chatSnapshotID(teamID: "team-1", originalSessionID: "memory-\(Self.uuid)")
        #expect(ChatKindClassifier.kind(of: Evidence(id: id, kind: "chat", isTeamSnapshot: true, hasOverallScore: true)) == .transcript)
    }

    @Test("When several rules hold, the first decides")
    func ruleOrder() {
        #expect(ChatKindClassifier.kind(of: Evidence(id: "memory-live-\(Self.uuid)")) == .memory)
        #expect(ChatKindClassifier.kind(of: Evidence(id: "course-quiz-live-\(Self.uuid)", hasOverallScore: true)) == .quizSitting)
        #expect(ChatKindClassifier.kind(of: Evidence(id: "ios-live-\(Self.uuid)", holdsWalkthroughStep: true)) == .voice)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, kind: "review", isNamedByWalkthroughProgress: true)) == .walkthrough)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, kind: "chat", hasGradedExchange: true)) == .review)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid, kind: "chat")) == .chat)
        #expect(ChatKindClassifier.kind(of: Evidence(id: Self.uuid)) == .chat)
    }
}
