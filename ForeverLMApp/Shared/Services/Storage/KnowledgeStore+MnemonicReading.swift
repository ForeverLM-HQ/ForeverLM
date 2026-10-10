import Foundation

// MARK: - A mnemonic reading's answers in Memory
//
// docs/memory-design.md, "Mnemonic reading". A grade the learner gives a
// reading's question keeps the question as a Memory card at once — Remembered
// as well as Forgot, since quantum.country schedules every answered question
// and the learner made the reading to remember the book — with that grade as
// its first attempt. Once kept, the card comes back in the card review on its
// schedule, and a later grade in the reading is written only by the card
// review's own rules. What the reading shows of the learner's answers is read
// from here, per learner, and never written into the reading.

/// What became of a grade given in a mnemonic reading.
enum MnemonicReadingAnswerOutcome: String, Equatable, Sendable {
    /// The question's first answer: its card was kept, with this grade as
    /// its first attempt.
    case kept
    /// A later answer, written as the card review writes one: the card was
    /// due.
    case recorded
    /// This sitting already answered the question; nothing more was written.
    case alreadyRecorded = "already_recorded"
    /// The card is not due, so the answer moves nothing: the reading shows
    /// when it comes back and writes nothing (`MemoryCardQueue.answerCounts`).
    case notCounted = "not_counted"
    /// The learner retired the card; it is never asked again.
    case retired

    init(_ outcome: MemoryCardAnswerOutcome) {
        switch outcome {
        case .recorded: self = .recorded
        case .alreadyRecorded: self = .alreadyRecorded
        case .notCounted: self = .notCounted
        case .retired: self = .retired
        }
    }

    /// Whether anything was written.
    var wroteAttempt: Bool { self == .kept || self == .recorded }
}

/// A grade given in a reading, and where the question stands after it.
struct MnemonicReadingAnswer: Equatable, Sendable {
    let outcome: MnemonicReadingAnswerOutcome
    let memory: MnemonicQuestionMemory
}

extension KnowledgeStore {
    /// A grade the learner gave a reading's question, in the sitting
    /// `sittingKey` names (the reading's id for one opening of it).
    ///
    /// - A question not answered before is kept as a card: its item
    ///   (`MnemonicQuestion.memoryItemID`, the same on every device, so two
    ///   Macs answering before they sync keep one card) anchored on its
    ///   quote, which its source's text must print, and this grade as its
    ///   first attempt — a `.discovery`, so it was never a new card dealt
    ///   from the day's allowance — written in one transaction, so the item
    ///   is never left without the answer that made it. The attempt's id is
    ///   the sitting's and the card's (`MemoryTutorIdentity.selfGradedAttemptID`),
    ///   one answer per card per sitting, as the card review writes them.
    /// - A question kept already is answered as the card review answers a
    ///   card (`recordSelfGradedMemoryCardAttempt`): written only when the
    ///   card is due, once a sitting, never for a retired card.
    ///
    /// Throws, and writes nothing, when the question's quote is not in its
    /// source's text, or its source is not in the library.
    func recordMnemonicReadingAnswer(
        _ question: MnemonicQuestion,
        remembered: Bool,
        sittingKey: String,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> MnemonicReadingAnswer {
        let sitting = sittingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sitting.isEmpty else {
            throw KnowledgeStoreError.invalidData("A reading's answer needs the sitting it was given in.")
        }
        let itemID = question.memoryItemID
        if try loadMemoryItem(itemID) != nil {
            let outcome = try recordSelfGradedMemoryCardAttempt(
                memoryItemID: itemID,
                prompt: question.question,
                remembered: remembered,
                sessionKey: sitting,
                at: now,
                calendar: calendar
            )
            return try answer(MnemonicReadingAnswerOutcome(outcome), itemID: itemID, calendar: calendar)
        }
        let anchor = try validatedMemorySourceAnchor(sourceID: question.sourceID, excerpt: question.quote)
        let item: MemoryItem
        do {
            item = try question.card.memoryItem(id: itemID, anchors: [anchor], at: now)
        } catch let error as MemoryCardError {
            throw KnowledgeStoreError.invalidData(
                "Question \(question.id) cannot be kept as a card: \(error.localizedDescription)"
            )
        }
        let attempt = MemoryAttempt(
            id: MemoryTutorIdentity.selfGradedAttemptID(sessionKey: sitting, memoryItemID: itemID),
            memoryItemID: itemID,
            attemptType: .discovery,
            prompt: question.question,
            learnerAnswer: MemoryAttempt.selfGradedAnswer,
            score: remembered ? 1 : 0,
            scheduleRating: remembered ? .good : .again,
            gradeState: .graded,
            attemptedAt: now
        )
        // Checked again inside the transaction: a card kept meanwhile by
        // another connection (an assistant's answer) is never overwritten,
        // and this sitting's answer is recorded on it once.
        let existing = try saveMemoryItemIfAbsent(item, recording: attempt)
        return try answer(existing == nil ? .kept : .recorded, itemID: itemID, calendar: calendar)
    }

    private func answer(
        _ outcome: MnemonicReadingAnswerOutcome,
        itemID: String,
        calendar: Calendar
    ) throws -> MnemonicReadingAnswer {
        guard let memory = try mnemonicQuestionMemory(itemID: itemID, calendar: calendar) else {
            throw KnowledgeStoreError.invalidData("Memory item \(itemID) does not exist.")
        }
        return MnemonicReadingAnswer(outcome: outcome, memory: memory)
    }

    /// Where one kept question stands in Memory, from its item and attempts;
    /// nil when no card was kept for it.
    func mnemonicQuestionMemory(itemID: String, calendar: Calendar = .current) throws -> MnemonicQuestionMemory? {
        guard let item = try loadMemoryItem(itemID) else { return nil }
        return MnemonicQuestionMemory(item: item, attempts: try loadMemoryAttempts(memoryItemID: itemID), calendar: calendar)
    }

    /// Where each of `questions` stands in the learner's Memory, by question
    /// id; a question not answered yet is absent. Reads only: one query a few
    /// hundred ids at a time finds which questions were kept, and only those
    /// items and their attempts are read.
    func mnemonicReadingMemory(
        for questions: [MnemonicQuestion],
        calendar: Calendar = .current
    ) throws -> [String: MnemonicQuestionMemory] {
        var questionIDByItemID: [String: String] = [:]
        for question in questions {
            questionIDByItemID[question.memoryItemID] = question.id
        }
        let itemIDs = Array(questionIDByItemID.keys).sorted()
        var kept: [String] = []
        var start = 0
        while start < itemIDs.count {
            let chunk = Array(itemIDs[start..<min(itemIDs.count, start + 400)])
            start += chunk.count
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try queryBind("SELECT id FROM memory_items WHERE id IN (\(placeholders))", bind: { statement in
                for (index, id) in chunk.enumerated() {
                    self.bind(statement, index + 1, id)
                }
            }) { statement in
                if let id = self.string(statement, 0) { kept.append(id) }
            }
        }
        var memory: [String: MnemonicQuestionMemory] = [:]
        for itemID in kept {
            guard let questionID = questionIDByItemID[itemID],
                  let standing = try mnemonicQuestionMemory(itemID: itemID, calendar: calendar) else { continue }
            memory[questionID] = standing
        }
        return memory
    }
}
