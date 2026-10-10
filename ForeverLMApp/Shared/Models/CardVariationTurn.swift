import Foundation

// MARK: - Memory as cards: the variation pass's turns
//
// docs/memory-design.md, "Variations". The two turns the day close's Card
// Variation pass sends and what it keeps of their answers
// (`CardVariationModelCard`, `CardVariationVerdict`, which the Mac's AI
// service decodes). Kept apart from `MemoryCardVariation.swift`, whose rules
// the iPhone's card review reads too.

/// The two turns the variation pass sends.
enum CardVariationTurn {
    /// The rewording call's cards, numbered from 1.
    static func rewording(_ cards: [CardVariationCandidate], sourceTitle: String) -> String {
        var lines = ["Source: \(FlashcardDeck.singleLine(sourceTitle))", "", "Cards:"]
        for (offset, card) in cards.enumerated() {
            lines.append("\(offset + 1). Question: \(FlashcardDeck.singleLine(card.wording))")
            lines.append("   Answer: \(FlashcardDeck.singleLine(card.back))")
            if !card.why.isEmpty {
                lines.append("   Why: \(FlashcardDeck.singleLine(card.why.joined(separator: " ")))")
            }
            if let quote = card.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                lines.append("   Passage: \u{201C}\(FlashcardDeck.singleLine(quote))\u{201D}")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The judging call's cards and their rewordings, numbered from 1; a
    /// card with none left after the code's checks is not shown.
    static func judging(_ cards: [CardVariationCandidate], rewordings: [Int: [String]]) -> String {
        var lines = ["Cards:"]
        for (offset, card) in cards.enumerated() {
            guard let candidates = rewordings[offset + 1], !candidates.isEmpty else { continue }
            lines.append("\(offset + 1). Question: \(FlashcardDeck.singleLine(card.wording))")
            lines.append("   Answer: \(FlashcardDeck.singleLine(card.back))")
            lines.append("   Rewordings:")
            for (index, candidate) in candidates.enumerated() {
                lines.append("   \(index + 1). \(candidate)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Each card's rewordings, by its number, once the code's checks have
    /// run (`MemoryCardVariation.acceptable`).
    static func checked(_ answer: [CardVariationModelCard], cards: [CardVariationCandidate]) -> [Int: [String]] {
        var checked: [Int: [String]] = [:]
        for entry in answer where cards.indices.contains(entry.card - 1) && checked[entry.card] == nil {
            let card = cards[entry.card - 1]
            checked[entry.card] = MemoryCardVariation.acceptable(entry.variants, wording: card.wording, back: card.back)
        }
        return checked
    }

    /// The rewordings the judge passed, by card number: those it said the
    /// back answers, and no more, without leaking it. One it gave no verdict
    /// on does not pass.
    static func judged(_ verdicts: [CardVariationVerdict], rewordings: [Int: [String]]) -> [Int: [String]] {
        var passed: [Int: [String]] = [:]
        for (card, candidates) in rewordings {
            passed[card] = candidates.enumerated().compactMap { index, candidate in
                let verdict = verdicts.first { $0.card == card && $0.variant == index + 1 }
                guard let verdict, verdict.answersIt, !verdict.leaksAnswer else { return nil }
                return candidate
            }
        }
        return passed
    }
}
