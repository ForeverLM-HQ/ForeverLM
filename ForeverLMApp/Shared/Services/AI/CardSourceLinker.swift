import Foundation
import OSLog

// MARK: - Cards that stand on several sources: the linker
//
// `CardSourceLinking` holds the pure half (the prompt, the turn, the checks);
// this is the half that reads the library and calls the model. Retrieval first:
// for each card, the other sources' passages nearest its question and answer,
// from the library's own hybrid search restricted to the sources asked about, so
// a source kept from AI never gives one. Then one judging call per dozen cards
// on the learner's Card Drafting route.
//
// Linking is an addition to a card, never a condition of it: a card with no
// other source is the ordinary card. A failed call is reported to the caller,
// which saves the cards without links and says so; nothing is guessed in its
// place.

/// The model and the embedder behind the linker, so its users are tested with
/// canned answers.
protocol CardSourceLinkBackend: Sendable {
    /// The vector of `text`, for the retrieval's semantic branch. Throws when
    /// no embedding model answers; retrieval then runs on text alone.
    func embed(_ text: String) async throws -> [Float]
    /// Which candidate passages state each card.
    func pick(user: String, usage: AIUsageSource) async throws -> [CardSourceLinkingVerdict]
}

/// The learner's Card Drafting route, resolved at each call.
struct LiveCardSourceLinkBackend: CardSourceLinkBackend {
    let aiService: AIService

    func embed(_ text: String) async throws -> [Float] {
        try await aiService.embedText(text)
    }

    func pick(user: String, usage: AIUsageSource) async throws -> [CardSourceLinkingVerdict] {
        guard let config = KeychainService.resolveConfig(for: .cardDrafting) else { throw CardDraftingError.noModel }
        return try await aiService.linkCardSources(user: user, source: usage, config: config)
    }
}

/// What linking one batch of cards found.
struct CardSourceLinkingResult: Equatable, Sendable {
    /// The links of each card, in the order the cards were given: one passage
    /// per other source, none for a card no other source states.
    var links: [[CardSourceLink]]
    /// How many model calls it took, for the usage the run reports.
    var calls = 0

    var linkedCount: Int { links.filter { !$0.isEmpty }.count }
}

enum CardSourceLinker {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "CardSourceLinking")

    /// The passages of `pool`'s sources (the whole library when nil) nearest
    /// each card (its question and answer), at most
    /// `CardSourceLinking.candidatesPerCard` for a card, one per source, never
    /// a passage of a source the card stands on already (`excluding`). Reads
    /// only: the hybrid search restricted to `pool`, then each source's stored
    /// text cut to the stretch around what matched.
    static func candidates(
        for cards: [(front: String, back: String)],
        excluding own: Set<String>,
        among givenPool: Set<String>?,
        storage: StorageService,
        backend: any CardSourceLinkBackend
    ) async -> [[CardSourceCandidate]] {
        let pool = givenPool.map { $0.subtracting(own) }
        if let pool, pool.isEmpty { return cards.map { _ in [] } }
        var titles: [String: String] = [:]
        var texts: [String: String] = [:]
        var result: [[CardSourceCandidate]] = []
        for card in cards {
            let query = "\(card.front) \(card.back)".trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                result.append([])
                continue
            }
            let vector: [Float]?
            do {
                vector = try await backend.embed(query)
            } catch {
                // The lexical branch still finds a passage that names it.
                logger.error("A card's words could not be embedded; searching by text: \(error.localizedDescription, privacy: .public)")
                vector = nil
            }
            let hits = await storage.searchSources(
                queryText: query,
                queryVector: vector,
                // Room for the card's own sources, which the search ranks first.
                limit: CardSourceLinking.candidatesPerCard + own.count,
                restrictedTo: pool
            )
            var found: [CardSourceCandidate] = []
            for hit in hits where !own.contains(hit.sourceId) && (pool?.contains(hit.sourceId) ?? true) {
                if texts[hit.sourceId] == nil {
                    guard let text = try? await storage.situatedSourceText(hit.sourceId) else { continue }
                    texts[hit.sourceId] = text
                }
                guard let text = texts[hit.sourceId] else { continue }
                let chunks = SourceEmbeddingText.textChunks(from: text)
                var passage = text
                if let chunkID = hit.bestChunkId,
                   let index = StorageService.sourceChunkIndex(fromSourceChunkEmbeddingId: chunkID),
                   chunks.indices.contains(index) {
                    passage = chunks[index]
                }
                let excerpt = SituatedPassageCutter.excerpt(passage, query: query)
                guard !excerpt.isEmpty else { continue }
                if titles[hit.sourceId] == nil {
                    titles[hit.sourceId] = (try? await storage.loadSourceWithoutContent(hit.sourceId))?.title ?? "Source"
                }
                found.append(CardSourceCandidate(sourceID: hit.sourceId, title: titles[hit.sourceId] ?? "Source", passage: excerpt))
                if found.count == CardSourceLinking.candidatesPerCard { break }
            }
            result.append(found)
        }
        return result
    }

    /// The other sources of `pool` (the whole library when nil) that state each card, one batch: the
    /// candidates, then the judge, then the quotes checked against the
    /// passages. No call is made when no card has a candidate. Throws when the
    /// judge cannot answer.
    static func link(
        cards: [(front: String, back: String)],
        excluding own: Set<String>,
        among pool: Set<String>?,
        storage: StorageService,
        backend: any CardSourceLinkBackend,
        usage: AIUsageSource
    ) async throws -> CardSourceLinkingResult {
        var result = CardSourceLinkingResult(links: Array(repeating: [], count: cards.count))
        guard !cards.isEmpty else { return result }
        let candidates = await candidates(for: cards, excluding: own, among: pool, storage: storage, backend: backend)
        // Only the cards that have something to judge go to the model, a
        // dozen to a call.
        let judged = cards.indices.filter { !candidates[$0].isEmpty }
        for start in stride(from: 0, to: judged.count, by: CardSourceLinking.cardsPerCall) {
            try Task.checkCancellation()
            let batch = Array(judged[start..<min(start + CardSourceLinking.cardsPerCall, judged.count)])
            let user = CardSourceLinking.message(
                cards: batch.map { cards[$0] },
                candidates: batch.map { candidates[$0] }
            )
            let verdicts = try await backend.pick(user: user, usage: usage)
            result.calls += 1
            let batchLinks = CardSourceLinking.links(
                from: verdicts,
                cardCount: batch.count,
                candidates: batch.map { candidates[$0] }
            )
            for (offset, index) in batch.enumerated() { result.links[index] = batchLinks[offset] }
        }
        return result
    }
}
