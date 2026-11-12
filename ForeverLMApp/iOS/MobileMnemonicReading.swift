import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

// A mnemonic reading on the iPhone and iPad (docs/memory-design.md, "Mnemonic
// reading (2026-10-03)"), the parts with no view and no CloudKit in them. The
// phone reads the body and places its questions with the Mac's own shared
// code (`MnemonicReading`, `MnemonicReadingPlacement`); what the Mac's store
// decides when a question is answered (`KnowledgeStore.recordMnemonicReadingAnswer`)
// is decided here over the items and attempts the phone holds, so the phone
// writes the very item and attempt the Mac would. Foundation-only and compiled
// into the macOS unit tests beside `MobileCardReview.swift`, so each rule is
// pinned against the Mac's store (`MobileMnemonicReadingTests`).

// MARK: - Recognising one

enum MobileMnemonicReading {
    /// The Mac's `ArtifactKind.mnemonicReading`, which the phone reads as a string.
    static let kind = "mnemonic_reading"

    /// Whether a record is a reading: by its kind, or, with no kind (an older
    /// build saved it back without one), by its body's marker line.
    static func isReading(kind: String?, markdown: String?) -> Bool {
        if kind == Self.kind { return true }
        guard kind == nil, let markdown else { return false }
        return MnemonicReading.isReadingMarkdown(markdown)
    }

    /// The Studio row's line: "Mnemonic reading · 12 sources · yesterday".
    static func outputLine(sourceCount: Int, madeAt: Date?) -> String {
        MobileNotebookOutputLine.line(kind: MnemonicReading.kindLabel, sourceCount: sourceCount, madeAt: madeAt)
    }

    /// One opening of a reading, as the Mac names its sittings: one answer
    /// per card per sitting, as the card review counts them.
    static func sittingKey(readingID: String, token: String) -> String {
        "reading-\(readingID)-\(token)"
    }

    /// The hex SHA-256 of a source's stored text, as the Mac's store hashes
    /// it for a Memory anchor (`PaperContentPreparationService.sha256`).
    static func sha256(_ text: String) -> String {
        text.sha256Hex
    }
}

extension MobileCloudArtifact {
    /// A mnemonic reading by its kind. One saved back with no kind is known
    /// only by its body, which the phone reads when it is opened
    /// (`MobileMnemonicReading.isReading(kind:markdown:)`).
    var isMnemonicReading: Bool {
        kind == MobileMnemonicReading.kind
    }
}

// MARK: - Answering one

/// What one Forgot or Remembered in a reading writes on the phone: exactly
/// what the Mac's `KnowledgeStore.recordMnemonicReadingAnswer` writes, decided
/// over the card's item and history as this phone holds them, before anything
/// goes to CloudKit.
///
/// - A question with no item on the phone is kept: its item
///   (`MnemonicQuestion.memoryItemID`, the same on every device) carries the
///   question's card face, origin `reading`, anchored on its quote, which the
///   source's text must print, and the grade is its first attempt — a
///   `.discovery`, `.graded`, "(self-graded)", score 1 and `good` or 0 and
///   `again`, the question as its prompt, under the sitting's and the card's
///   id. The two are written together; an item another device kept first
///   takes the attempt alone, as the Mac's `saveMemoryItemIfAbsent` does.
/// - A question whose item the phone holds is answered by the card review's
///   rules (`MobileSelfGradedAnswer`): only when due, once a sitting, never
///   for a retired card.
enum MobileMnemonicReadingAnswer {
    enum Decision: Equatable, Sendable {
        /// The first answer: keep the card, with this attempt as its first.
        case keep(item: MemoryItem, attempt: MemoryAttempt)
        /// A later answer to a kept card, written as the card review writes one.
        case write(MemoryAttempt)
        /// Write nothing (`MemoryCardAnswerOutcome`).
        case skip(MemoryCardAnswerOutcome)
    }

    enum Refusal: LocalizedError, Equatable {
        case noSitting
        /// The source's text could not be read, so the quote cannot be checked.
        case noText
        /// The source's text no longer prints the quote.
        case passageNotFound
        /// The question cannot be a card (no question or no answer).
        case cannotKeep

        var errorDescription: String? {
            switch self {
            case .noSitting: return "An answer needs the sitting it was given in."
            case .noText: return "This source's text is not on this iPhone yet."
            case .passageNotFound: return "Its passage is no longer in this text, so it cannot be kept."
            case .cannotKeep: return "This question cannot be kept as a card."
            }
        }
    }

    /// `heldItem` is the question's item when the phone holds one, `history`
    /// its attempts (any other item's are ignored), `sourceText` the source's
    /// stored text as synced, which a first answer anchors on.
    static func decide(
        _ question: MnemonicQuestion,
        remembered: Bool,
        sittingKey: String,
        heldItem: MemoryItem?,
        history: [MemoryAttempt],
        sourceText: String?,
        at now: Date,
        calendar: Calendar = .current
    ) throws -> Decision {
        let sitting = sittingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sitting.isEmpty else { throw Refusal.noSitting }
        if let heldItem {
            switch try MobileSelfGradedAnswer.decide(
                item: heldItem,
                history: history,
                prompt: question.question,
                remembered: remembered,
                sessionKey: sitting,
                practice: false,
                at: now,
                calendar: calendar
            ) {
            case .write(let attempt): return .write(attempt)
            case .skip(let outcome): return .skip(outcome)
            }
        }
        let item = try keptItem(question, sourceText: sourceText, at: now)
        return .keep(item: item, attempt: firstAttempt(question, remembered: remembered, sittingKey: sitting, at: now))
    }

    /// The question's card as the Mac's store keeps it: anchored on its
    /// quote, which `sourceText` must print (`validatedMemorySourceAnchor`).
    static func keptItem(_ question: MnemonicQuestion, sourceText: String?, at now: Date) throws -> MemoryItem {
        guard let sourceText, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal.noText
        }
        let excerpt = question.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty, MemoryGroundingText(sourceText).contains(excerpt) else {
            throw Refusal.passageNotFound
        }
        let anchor = MemorySourceAnchorValidation(
            sourceID: question.sourceID,
            excerpt: excerpt,
            sourceSHA256: MobileMnemonicReading.sha256(sourceText)
        )
        do {
            return try question.card.memoryItem(id: question.memoryItemID, anchors: [anchor], at: now)
        } catch {
            throw Refusal.cannotKeep
        }
    }

    /// The grade as a kept card's first attempt.
    static func firstAttempt(_ question: MnemonicQuestion, remembered: Bool, sittingKey: String, at now: Date) -> MemoryAttempt {
        MemoryAttempt(
            id: MemoryTutorIdentity.selfGradedAttemptID(sessionKey: sittingKey, memoryItemID: question.memoryItemID),
            memoryItemID: question.memoryItemID,
            attemptType: .discovery,
            prompt: question.question,
            learnerAnswer: MemoryAttempt.selfGradedAnswer,
            score: remembered ? 1 : 0,
            scheduleRating: remembered ? .good : .again,
            gradeState: .graded,
            attemptedAt: now
        )
    }
}

// MARK: - The learner's answers, read from what the phone holds

enum MobileMnemonicReadingMemory {
    /// Where each of `questions` stands in the learner's Memory, by question
    /// id, the Mac's `mnemonicReadingMemory(for:)` over the items and
    /// attempts the phone holds; a question not answered yet is absent.
    static func standing(
        of questions: [MnemonicQuestion],
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        calendar: Calendar = .current
    ) -> [String: MnemonicQuestionMemory] {
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var memory: [String: MnemonicQuestionMemory] = [:]
        for question in questions {
            guard memory[question.id] == nil, let item = itemsByID[question.memoryItemID] else { continue }
            memory[question.id] = MnemonicQuestionMemory(
                item: item,
                attempts: attemptsByItemID[item.id] ?? [],
                calendar: calendar
            )
        }
        return memory
    }

    /// An answered question's quiet line, the Mac's: "Remembered · back in
    /// 4 days", "Forgot · due now", "Retired".
    static func standingLine(_ memory: MnemonicQuestionMemory, now: Date = Date()) -> String {
        if memory.isRetired { return "Retired" }
        let grade = memory.lastRemembered == false ? "Forgot" : "Remembered"
        if memory.isDue(at: now) { return "\(grade) · due now" }
        let when = memory.dueAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return "\(grade) · back \(when)"
    }

    /// Whether a question can be answered here, the Mac's `canAnswer`: kept
    /// already (a later grade needs no passage), or its source's text is
    /// read and places it.
    static func canAnswer(_ questionID: String, sourceID: String?, memory: [String: MnemonicQuestionMemory], texts: [String: MnemonicReadingSourceText]) -> Bool {
        if memory[questionID] != nil { return true }
        guard let sourceID, case .loaded(let layout) = texts[sourceID] else { return false }
        return !layout.unplaced.contains { $0.id == questionID }
    }
}
