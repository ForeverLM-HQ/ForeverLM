import CloudKit
import CryptoKit
import Foundation

// Persists a completed iOS review or chat (typed or spoken) so it syncs back to
// the Mac and shows up in the centralized review history: the Chat and its
// Exchanges through the phone's writer, which the replica sends (§3.5.13,
// §3.5.14).

struct MobileReviewRecordedExchange {
    let question: String
    let userAnswer: String
    let evaluation: String?
    let score: Double?
    let answeredAt: Date
}

struct MobileReviewResult {
    let sessionID: String
    let topic: String
    /// The primary source when the conversation opened or loaded one. A
    /// session with none is still a first-class review session and persists
    /// with an empty source list.
    let sourceID: String?
    /// Goal that launched this review, when the mobile surface has that context.
    /// Reading chats and voice-selected sources may legitimately be unscoped.
    let goalID: String?
    let startedAt: Date
    let endedAt: Date
    /// Nil when the session was not graded. The Mac reads this as the source's
    /// most recent recall score, and CLAUDE.md forbids heuristic grading, so an
    /// ungraded session (a reading chat) must record no score rather than invent one.
    let overallScore: Double?
    let summary: String
    let exchanges: [MobileReviewRecordedExchange]
    let gaps: [MobileReviewGap]
    /// Provenance the Mac stores against every exchange, and the provider and
    /// model that actually answered. All three differ per surface — a
    /// hands-free review and a reading chat run different prompts on different
    /// models, and the review's grader is a user choice between a cloud model
    /// and Apple's on-device one — so none can be hardcoded in the recorder
    /// without writing false provenance.
    let knowledgeNote: String
    let modelProvider: String
    let modelID: String
    /// Other sources touched in the same session (a notebook chat reads
    /// several). The primary `sourceID` stays first so the
    /// Mac's "most recent recall" attribution is unchanged for single-source
    /// quizzes. Declared last with a default so existing single-source call
    /// sites and their memberwise argument order are untouched.
    var additionalSourceIDs: [String] = []
    /// What the conversation is (`Chat.kind`, D50), from the surface that recorded it: a reading or
    /// notebook chat `chat`, a walk's chat `walkthrough`, a hands-free review `review`. It is
    /// written on the Chat; nil falls back to `ChatKindClassifier`'s reading of the session.
    var kind: ChatKind? = nil
}

extension MobileReviewResult {
    /// The chat as the writer records it (§3.5.13, §3.5.14): its turns, ids and sources, under the
    /// creation site's kind.
    var chatRecord: MobileChatRecord {
        var sourceIDs = sourceID.map { [$0] } ?? []
        for extra in additionalSourceIDs where !sourceIDs.contains(extra) { sourceIDs.append(extra) }
        let kind = kind ?? ChatKindClassifier.kind(of: ChatKindClassifier.Evidence(
            id: sessionID, hasOverallScore: overallScore != nil, hasGradedExchange: exchanges.contains { $0.score != nil }
        ))
        return MobileChatRecord(
            id: sessionID, kind: kind, notebookID: goalID, title: topic, startedAt: startedAt, endedAt: endedAt, summary: summary,
            overallScore: overallScore, sourceIDs: sourceIDs, modelProvider: modelProvider, modelID: modelID,
            exchanges: exchanges.enumerated().map { index, exchange in
                MobileChatRecord.Exchange(
                    id: MobileReviewSessionRecorder.exchangeID(sessionID: sessionID, sequence: index + 1), seq: index + 1,
                    question: exchange.question, userAnswer: exchange.userAnswer, evaluation: exchange.evaluation, score: exchange.score,
                    answeredAt: exchange.answeredAt, sourceRefs: sourceIDs, knowledgeNote: knowledgeNote
                )
            }
        )
    }
}

/// The turns a continued notebook chat added, for appending to its saved
/// session (`MobileReviewSessionRecorder.appendChatExchanges`).
struct MobileReviewChatAppend: Sendable {
    let sessionID: String
    /// Every turn the sitting added so far, in order, under ids that stay the
    /// same from one save of the sitting to the next.
    let exchanges: [MobileNotebookChatContinuation.AddedExchange]
    let knowledgeNote: String
    /// The provider and model that answered the sitting's last turn.
    let modelProvider: String
    let modelID: String
    let endedAt: Date
}

/// A source's identity beside a record that names it, so another device whose
/// copy of the source has another id finds it (the Mac's
/// `CloudKitSourceIdentityPayload`).
struct MobileReviewSourceIdentityPayload: Codable, Equatable {
    let sourceID: String
    let url: String?
    let normalizedURL: String?
    let doi: String?
    let publishedDOI: String?
}

/// A review's and a chat's records, written through the phone's writer (`MobileRecordWriter`): the Chat
/// and its Exchanges, and for a memory turn the card it keeps and the answer in this device's Sitting
/// (§3.5.13, §3.5.14, §3.5.22, §3.5.23). The replica sends them.
actor MobileReviewSessionRecorder {
    static let shared = MobileReviewSessionRecorder()

    /// The Chat and its Exchanges; a finished review also logs each reviewed source on the device's
    /// ActivityLog (completed), completes its Placement (automatic on the day when it had none) and the
    /// source, ends the device's Sitting for the chat and sends both now (D44).
    func record(
        _ result: MobileReviewResult,
        reviewedSourceIDs: [String] = []
    ) async throws {
        let writer = try await MobileRecordWriter.required()
        let chat = result.chatRecord
        let reviewed = Set(reviewedSourceIDs)
        guard reviewed.isSubset(of: Set(chat.sourceIDs)) else { throw MobileReviewSessionRecorderError.invalidReviewedSources }
        let endedAt = result.endedAt
        try await writer.transaction { write in
            try write.recordChat(chat)
            for (index, sourceID) in reviewed.sorted().enumerated() {
                try write.recordSourceActivity(sourceID: sourceID, day: MemoryReviewGoal.dayKey(for: endedAt), kind: "review", at: endedAt,
                                               completed: true, fraction: nil, engagedSeconds: 0)
                try write.consumePlacement(sourceID, at: endedAt, order: index)
            }
            try write.endSitting(chatID: chat.id, at: endedAt)
        }
        try await writer.flushLearningHistory()
    }

    /// Appends a continued chat's turns as new Exchange records after the chat's own (§3.5.14); no
    /// whole-chat save to merge.
    func appendChatExchanges(_ append: MobileReviewChatAppend) async throws {
        guard !append.exchanges.isEmpty else { return }
        do {
            try await MobileRecordWriter.required().transaction {
                try $0.appendExchanges(append.exchanges, toChat: append.sessionID, knowledgeNote: append.knowledgeNote,
                                       modelProvider: append.modelProvider, modelID: append.modelID, endedAt: append.endedAt)
            }
        } catch MobileRecordWriterError.chatGone {
            throw MobileReviewSessionRecorderError.chatNotInCloud
        }
    }

    /// The written form of `recordActiveMemoryAttempt` (§3.5.13, §3.5.22, §3.5.23): in one replica
    /// transaction, the chat and its exchanges, the card when this turn keeps it, and the attempt as an
    /// answer in the device's Sitting for the chat. A card kept first elsewhere with other wording wins;
    /// the same answer again is a replay, another under its id refused.
    static func recordActiveMemoryAttempt(
        _ attempt: MemoryAttempt,
        in result: MobileReviewResult,
        creating item: MemoryItem?,
        asserted: MemoryItem,
        fingerprint: String,
        writer: MobileRecordWriter
    ) async throws -> (attemptRecordName: String, itemRecordName: String?, canonicalItem: MemoryItem?) {
        // The chat is still running: written active, with no end.
        let full = result.chatRecord
        let chat = MobileChatRecord(id: full.id, kind: full.kind, notebookID: full.notebookID, title: full.title, startedAt: full.startedAt,
                                    endedAt: nil, summary: full.summary, overallScore: full.overallScore, sourceIDs: full.sourceIDs,
                                    modelProvider: full.modelProvider, modelID: full.modelID, exchanges: full.exchanges)
        try await writer.transaction { write in
            try write.recordChat(chat)
            if let item {
                if case .keptElsewhere(let held) = try write.keepCard(item) {
                    throw MobileReviewSessionRecorderError.canonicalMemoryItemWon(held)
                }
            } else {
                guard let held = try write.keptItem(asserted.id) else { throw MobileReviewSessionRecorderError.memoryItemConflict }
                guard MemoryTutorIdentity.hasSameImmutableCurriculum(held, asserted) else {
                    throw MobileReviewSessionRecorderError.canonicalMemoryItemWon(held)
                }
            }
            guard try write.recordAnswer(attempt, curriculumFingerprint: fingerprint) != .conflict else {
                throw MobileMemoryAttemptRecorderError.immutableConflict
            }
        }
        return (MobileMemoryAttemptRecorder.recordName(for: attempt.id), memoryItemRecordName(for: asserted.id), asserted)
    }

    /// The name a card's records go by, the Mac's (`CloudKitRecordMapper.recordName(for: .memoryItem, …)`).
    static func memoryItemRecordName(for itemID: String) -> String {
        let digest = SHA256.hash(data: Data("memoryItem:\(itemID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The same id the Mac derives for an exchange it saves without one.
    static func exchangeID(sessionID: String, sequence: Int) -> String {
        "\(sessionID)::exchange::\(String(format: "%04d", sequence))"
    }
}

enum MobileReviewSessionRecorderError: LocalizedError {
    case conflict
    case incompleteAtomicSave
    case invalidMemoryLink
    case memoryTranscriptMismatch
    case memoryItemConflict
    case canonicalMemoryItemWon(MemoryItem)
    case invalidReviewedSources
    case invalidSchedulePlacement
    case missingNotebook
    case completedSessionConflict
    case chatNotInCloud
    case unreadableChat

    var errorDescription: String? {
        switch self {
        case .chatNotInCloud:
            return "This chat is no longer in iCloud."
        case .unreadableChat:
            return "This chat's saved record could not be read."
        case .conflict:
            return "The chat changed on another device while it was being saved."
        case .incompleteAtomicSave:
            return "CloudKit did not confirm both the memory attempt and its transcript."
        case .invalidMemoryLink:
            return "The memory attempt does not point to an exchange in this voice transcript."
        case .memoryTranscriptMismatch:
            return "The memory attempt does not exactly match its voice transcript exchange."
        case .memoryItemConflict:
            return "A different durable memory item already uses this intake identity."
        case .canonicalMemoryItemWon:
            return "Another device already created the canonical memory idea for this source."
        case .invalidReviewedSources:
            return "The completed memory review referenced a source outside its durable session."
        case .invalidSchedulePlacement:
            return "The memory review's Schedule relationship could not be validated."
        case .missingNotebook:
            return "A Notebook linked to this memory review is not available in CloudKit."
        case .completedSessionConflict:
            return "This completed memory review was retried with different immutable content."
        }
    }
}

