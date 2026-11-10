import CryptoKit
import Foundation

/// The phone's memory answers (§3.5.22, §3.5.23): an attempt is an answer in this device's `Sitting`
/// and a card kept here a `Card` (`MobileMemoryRecords`), written through `MobileRecordWriter`, which the
/// replica sends. A graded memory turn is written before the tutor is allowed to continue; the card
/// review writes its self-graded answers here (`recordSelfGraded`), on the card's existing item.
actor MobileMemoryAttemptRecorder {
    static let shared = MobileMemoryAttemptRecorder()

    static let entityRawValue = "memoryAttempt"

    private let recordWriter: @Sendable () async -> MobileRecordWriter?

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() }) {
        recordWriter = writer
    }

    private func requiredWriter() async throws -> MobileRecordWriter {
        try await MobileRecordWriter.required(from: recordWriter)
    }

    /// The canonical record name of an attempt (the Mac's `CloudKitRecordMapper.recordName(for:
    /// .memoryAttempt, …)`), so the mobile catalog can publish the just-saved attempt at once.
    static func recordName(for attemptID: String) -> String {
        let digest = SHA256.hash(data: Data("\(entityRawValue):\(attemptID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Written once into the device's Sitting; the same answer again is a replay, another under this id
    /// is refused.
    func record(
        _ attempt: MemoryAttempt,
        parentCurriculumFingerprint: String
    ) async throws -> String {
        let outcome = try await requiredWriter().transaction { try $0.recordAnswer(attempt, curriculumFingerprint: parentCurriculumFingerprint) }
        guard outcome != .conflict else { throw MobileMemoryAttemptRecorderError.immutableConflict }
        return Self.recordName(for: attempt.id)
    }

    /// One self-graded card answer from the card review, written once: `.recorded` when this call saved
    /// it, `.alreadyRecorded` when an answer under its id is held already, whatever it holds. The id is
    /// the sitting's and the card's, so only this sitting writes it: a retry, or the answer sent twice,
    /// counts once, and a repeat never overwrites the first answer.
    func recordSelfGraded(
        _ attempt: MemoryAttempt,
        parentCurriculumFingerprint: String
    ) async throws -> MemoryCardAnswerOutcome {
        let outcome = try await requiredWriter().transaction {
            try $0.recordAnswer(attempt, curriculumFingerprint: parentCurriculumFingerprint, anyHeldCounts: true)
        }
        return outcome == .recorded ? .recorded : .alreadyRecorded
    }

    /// What a mnemonic reading's first answer did (`recordKeeping`).
    enum KeepResult: Equatable, Sendable {
        /// The card was kept: its item and first attempt saved together.
        case kept
        /// Another device kept the card first. The answer went on its item
        /// (`.recorded`), or this sitting's answer was there already.
        case keptElsewhere(MemoryItem, MemoryCardAnswerOutcome)
    }

    /// A mnemonic reading's first answer (`MobileMnemonicReadingAnswer`): the Card and its first answer in
    /// one transaction, so the card is never sent without the answer that kept it. A card kept first
    /// elsewhere keeps its wording, and the answer goes on it.
    func recordKeeping(
        _ item: MemoryItem,
        sourceIdentities: [MobileReviewSourceIdentityPayload],
        firstAttempt attempt: MemoryAttempt
    ) async throws -> KeepResult {
        guard attempt.memoryItemID == item.id else { throw MobileMemoryAttemptRecorderError.immutableConflict }
        return try await requiredWriter().transaction { write -> KeepResult in
            switch try write.keepCard(item) {
            case .kept:
                let outcome = try write.recordAnswer(attempt, curriculumFingerprint: MemoryTutorIdentity.immutableCurriculumFingerprint(item))
                guard outcome != .conflict else { throw MobileMemoryAttemptRecorderError.immutableConflict }
                return .kept
            case .keptElsewhere(let held):
                let outcome = try write.recordAnswer(attempt, curriculumFingerprint: MemoryTutorIdentity.immutableCurriculumFingerprint(held),
                                                     anyHeldCounts: true)
                return .keptElsewhere(held, outcome == .recorded ? .recorded : .alreadyRecorded)
            }
        }
    }
}

enum MobileMemoryAttemptRecorderError: LocalizedError {
    case conflict
    case immutableConflict
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "The memory attempt changed concurrently and could not be saved."
        case .immutableConflict:
            return "A different memory attempt already uses this review identity."
        case .invalidPayload:
            return "The saved memory attempt could not be read."
        }
    }
}
