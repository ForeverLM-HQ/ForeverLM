import Foundation

// MARK: - Memory as cards: variations
//
// docs/memory-design.md, "Variations". The product owner, 2026-09-30: cards "can be
// served to us with variations". A kept card is asked in its own words until
// it has been remembered twice; the next day close rewords it — three
// rewordings asking for the same back from another angle, then a separate
// judge pass — and the rewordings that also pass the checks here (no longer
// than 1.3 times the card's question, new, the answer not in them) join its
// rotation, stored in the card's `cards.state.<deckID>` row. The rotation
// (`MemoryCardWording`) never asks the wording asked last; "Always ask it
// this way" turns variation off for a card; "This asks something else"
// records a failed attempt and retires that rewording; and a rewording missed
// more often than the card's own words over three uses or more retires
// itself. Retirements are read off the attempts, which are synced and never
// change, so no device has to write one. Everything here is pure, and
// compiled into the iPhone app too, whose card review asks the same rotation;
// the day close's two turns are `CardVariationTurn.swift`.

enum MemoryCardVariation {
    /// Rewordings asked for each card.
    static let variantCount = 3
    /// The longest a rewording may run, against the card's own question.
    static let maximumLengthRatio = 1.3
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

    /// Whether the next day close rewords this card: an active card,
    /// remembered twice, with "Always ask it this way" off and no rewording
    /// made yet. An item from before cards is reworded once the learner has
    /// gone through it in To Check (its row says kept): until then it waits
    /// there, and a row written for its variants would take it out.
    static func needsVariants(
        item: MemoryItem,
        face: MemoryCard,
        state: MemoryCardState?,
        attempts: [MemoryAttempt]
    ) -> Bool {
        guard item.status == .active else { return false }
        if face.origin == .legacy, state?.status != .kept { return false }
        if let state, state.alwaysAsk || state.variedAt != nil || !state.variants.isEmpty { return false }
        return successes(attempts) >= MemoryCardWording.successesBeforeVariants
    }

    /// The rewordings that pass the code's checks, in the order they came,
    /// at most `variantCount`: one line each, no longer than 1.3 times
    /// `wording`, unlike the card's wording and each other, and not
    /// containing the back when the back is a phrase (a one-word answer may
    /// well be named in a fair question; the judge rules on that).
    static func acceptable(_ candidates: [String], wording: String, back: String) -> [String] {
        let limit = Int((Double(wording.count) * maximumLengthRatio).rounded(.down))
        let backWords = compared(back)
        let leakable = backWords.split(separator: " ").count >= 4
        var seen: Set<String> = [compared(wording)]
        var kept: [String] = []
        for candidate in candidates {
            guard kept.count < variantCount else { break }
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(where: \.isNewline), text.count <= limit else { continue }
            let key = compared(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if leakable, key.contains(backWords) { continue }
            kept.append(text)
        }
        return kept
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

/// One card the day close rewords, as the pass reads it.
struct CardVariationCandidate: Equatable, Sendable {
    let itemID: String
    let cardID: String
    /// The deck whose `cards.state.<deckID>` row keeps its variants.
    let deckID: String
    /// The source it is first anchored on: cards are reworded a source at a
    /// time.
    let sourceID: String
    /// Its wording as asked now: the learner's rewording, else its front.
    let wording: String
    let back: String
    let why: [String]
    let quote: String?

    /// Every card of `items` due its variants, oldest kept first.
    static func dueVariants(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        state: (_ cardID: String, _ deckID: String) -> MemoryCardState?
    ) -> [CardVariationCandidate] {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        return items
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            .compactMap { item in
                let history = attemptsByItemID[item.id] ?? []
                guard let face = MemoryCard.face(of: item, attempts: history),
                      let deckID = face.stateDeckID(in: item),
                      let anchor = item.sources.min(by: {
                          if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                          return $0.id < $1.id
                      }) else { return nil }
                let row = state(face.cardID, deckID)
                guard MemoryCardVariation.needsVariants(item: item, face: face, state: row, attempts: history) else { return nil }
                return CardVariationCandidate(
                    itemID: item.id,
                    cardID: face.cardID,
                    deckID: deckID,
                    sourceID: anchor.sourceID,
                    wording: face.wording(state: row),
                    back: face.back,
                    why: face.why,
                    quote: anchor.excerpt
                )
            }
    }
}
