import Foundation

// MARK: - Memory as cards: variations
//
// docs/memory-design.md, "Variations". A kept card that has rewordings in its
// `cards.state.<deckID>` row is asked in them: the rotation (`MemoryCardWording`)
// never asks the wording asked last; "Always ask it this way" turns variation
// off for a card; "This asks something else" records a failed attempt and
// retires that rewording; and a rewording missed more often than the card's
// own words over three uses or more retires itself. Retirements are read off
// the attempts, which are synced and never change, so no device has to write
// one. Nothing writes new rewordings. Everything here is pure, and compiled into the iPhone
// app too, whose card review asks the same rotation.

enum MemoryCardVariation {
    /// What a "This asks something else" attempt records as its error.
    static let askedSomethingElse = "asked something else"
    /// Uses of a rewording before its misses can retire it.
    static let driftMinimumUses = 3

    /// The card's successes: graded answers not rated again.
    static func successes(_ attempts: [MemoryAttempt]) -> Int {
        attempts.reduce(0) { count, attempt in
            guard attempt.gradeState == .graded, let rating = attempt.scheduleRating, rating != .again else { return count }
            return count + 1
        }
    }

    /// Lower case, letters, digits and single spaces: how two wordings are
    /// told apart.
    static func compared(_ text: String) -> String {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                word.append(scalar)
            } else if !word.isEmpty {
                words.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words.joined(separator: " ")
    }

    /// The rewordings the attempts retire: one the learner said asks
    /// something else, and one missed more often than the card's own wording
    /// over three uses or more. By their words, trimmed, as asked.
    static func retired(variants: [String], wording: String, attempts: [MemoryAttempt]) -> Set<String> {
        let variantTexts = variants.map(trimmed)
        var retired = Set<String>()
        for attempt in attempts where attempt.gradeState == .failed && attempt.gradingError == askedSomethingElse {
            let asked = trimmed(attempt.prompt)
            if variantTexts.contains(asked) { retired.insert(asked) }
            if let index = askedSomethingElseVariantIndex(attempt), variantTexts.indices.contains(index) {
                retired.insert(variantTexts[index])
            }
        }
        let own = missRate(of: trimmed(wording), in: attempts)
        for variant in variantTexts where !retired.contains(variant) {
            let uses = graded(variant, in: attempts)
            guard uses.count >= driftMinimumUses else { continue }
            let misses = uses.filter { $0.scheduleRating == .again }.count
            if Double(misses) / Double(uses.count) > (own ?? 0) { retired.insert(variant) }
        }
        return retired
    }

    /// The share of the graded answers to `wording` that were misses; nil
    /// when it was never answered.
    private static func missRate(of wording: String, in attempts: [MemoryAttempt]) -> Double? {
        let uses = graded(wording, in: attempts)
        guard !uses.isEmpty else { return nil }
        return Double(uses.filter { $0.scheduleRating == .again }.count) / Double(uses.count)
    }

    private static func graded(_ wording: String, in attempts: [MemoryAttempt]) -> [MemoryAttempt] {
        attempts.filter { $0.gradeState == .graded && $0.scheduleRating != nil && trimmed($0.prompt) == wording }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: "This asks something else"

    /// The attempt's evidence: which of the card's rewordings it was,
    /// counting from 0 in the state row's `variants`.
    static func askedSomethingElseEvidence(variantIndex: Int) -> String {
        "{\"variant\":\(variantIndex)}"
    }

    static func askedSomethingElseVariantIndex(_ attempt: MemoryAttempt) -> Int? {
        guard let json = attempt.evidenceJSON, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["variant"] as? NSNumber else { return nil }
        return number.intValue
    }

    /// "This asks something else" on a rewording, as an attempt: failed, so
    /// it moves no schedule, with the rewording as its prompt and its place
    /// in the card's variants as evidence. `id` is the caller's
    /// (`KnowledgeStore.recordMemoryCardAskedSomethingElse` derives it from
    /// the sitting, so one sitting records it once).
    static func askedSomethingElseAttempt(
        id: String,
        memoryItemID: String,
        prompt: String,
        variantIndex: Int,
        at attemptedAt: Date
    ) -> MemoryAttempt {
        MemoryAttempt(
            id: id,
            memoryItemID: memoryItemID,
            attemptType: .review,
            prompt: prompt,
            // Not an answer: the learner said the wording asks for something
            // other than the card's back.
            learnerAnswer: "",
            gradeState: .failed,
            gradingError: askedSomethingElse,
            evidenceJSON: askedSomethingElseEvidence(variantIndex: variantIndex),
            attemptedAt: attemptedAt
        )
    }
}
