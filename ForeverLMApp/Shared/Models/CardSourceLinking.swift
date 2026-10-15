import Foundation

// MARK: - Cards that stand on several sources: finding the other sources
//
// docs/memory-design.md, "Cards stand on every source that prints them". A card
// is about an idea, and an idea is often printed in more than one of the
// learner's sources: a talk and the paper behind it, two lectures that cover
// the same mechanism. A kept card is anchored on every source that states it,
// so reviewing it shows where each one does.
//
// Finding them is two steps, and only the second is a model's. The first is
// retrieval: the passages of the other sources nearest the card's question and
// answer (`CardSourceLinker`, the library's own hybrid search). The second is a
// judgment: which of those passages state what the card asks, in substance,
// rather than sharing its topic. The model answers with a candidate's number
// and the words of the passage that state it; the app turns the number into a
// source id and checks the words against the passage and, when the card is
// saved or kept, against the source's whole text. The model never names a
// source or writes an id (AGENTS.md, "Never let an LLM decide identity").
//
// Pure and Foundation only: the prompt, the turn, the answer and the checks.

/// A passage of another source offered as a card's possible second source.
struct CardSourceCandidate: Equatable, Sendable {
    let sourceID: String
    let title: String
    /// A stretch of the source's own text, about 600 characters: what a quote
    /// is copied from.
    let passage: String
}

/// The judge's picks for one card.
struct CardSourceLinkingVerdict: Decodable, Equatable, Sendable {
    let card: Int
    let links: [Pick]

    struct Pick: Decodable, Equatable, Sendable {
        /// The candidate's number under the card, from 1.
        let candidate: Int
        /// The words of its passage that state what the card asks.
        let quote: String
    }

    init(card: Int, links: [Pick]) {
        self.card = card
        self.links = links
    }

    private enum CodingKeys: String, CodingKey { case card, links }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        card = try container.decode(Int.self, forKey: .card)
        links = try container.decodeIfPresent([Pick].self, forKey: .links) ?? []
    }
}

struct CardSourceLinkingAnswer: Decodable, Sendable {
    let cards: [CardSourceLinkingVerdict]
}

enum CardSourceLinking {
    /// The most candidate passages one card is judged against.
    static let candidatesPerCard = 4
    /// The most cards one judging call takes, so its answer fits its budget.
    static let cardsPerCall = 12

    /// The user message of one judging call: each card with its question and
    /// answer, and under it the numbered passages of other sources. A card
    /// with no candidate is left out of the turn (it has nothing to judge).
    static func message(cards: [(front: String, back: String)], candidates: [[CardSourceCandidate]]) -> String {
        var lines: [String] = []
        for (index, card) in cards.enumerated() where index < candidates.count && !candidates[index].isEmpty {
            lines.append("Card \(index + 1)")
            lines.append("Question: \(singleLine(card.front))")
            lines.append("Answer: \(singleLine(card.back))")
            for (number, candidate) in candidates[index].enumerated() {
                lines.append("Passage \(number + 1) (from \(singleLine(candidate.title))): \(singleLine(candidate.passage))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The links the verdicts give each card: a picked candidate becomes its
    /// source and the quote the judge gave, only when the passage prints that
    /// quote word for word (`MemoryGroundingText`). A number that names no
    /// candidate, a quote the passage does not print, a source picked twice
    /// for one card and a second passage of a source already linked are
    /// dropped, so a card's links are one passage per source.
    static func links(
        from verdicts: [CardSourceLinkingVerdict],
        cardCount: Int,
        candidates: [[CardSourceCandidate]]
    ) -> [[CardSourceLink]] {
        var result = Array(repeating: [CardSourceLink](), count: cardCount)
        for verdict in verdicts {
            let index = verdict.card - 1
            guard result.indices.contains(index), candidates.indices.contains(index) else { continue }
            var seenSources = Set<String>()
            var chosen: [CardSourceLink] = []
            for pick in verdict.links {
                let slot = pick.candidate - 1
                guard candidates[index].indices.contains(slot) else { continue }
                let candidate = candidates[index][slot]
                let quote = pick.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !quote.isEmpty,
                      MemoryGroundingText(candidate.passage).contains(quote),
                      seenSources.insert(candidate.sourceID).inserted else { continue }
                chosen.append(CardSourceLink(sourceID: candidate.sourceID, quote: quote))
            }
            result[index] = CardSourceLink.normalized(chosen)
        }
        return result
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
