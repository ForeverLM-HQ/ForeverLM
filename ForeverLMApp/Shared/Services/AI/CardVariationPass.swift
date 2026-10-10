import Foundation
import OSLog

/// What one variation run did, for the day close's receipt.
struct CardVariationReport: Equatable, Sendable {
    /// Cards reworded this run, whether or not a rewording passed.
    var reworded = 0
    /// Of those, the cards with a rewording in their rotation now.
    var varied = 0
    /// Cards left for the next day close: the background cap stopped the run.
    var waiting = 0
    var failures: [String] = []
}

/// A card's rewordings as its state row keeps them.
struct CardVariationWrite: Equatable, Sendable {
    let cardID: String
    let itemID: String
    /// The rewordings that passed, possibly none.
    let variants: [String]
}

/// Rewords the cards that earned it, at the day close (docs/memory-design.md,
/// "Variations"; decisions 2026-09-30, the product owner's call 4: after a card's
/// second success, not at drafting or Keep). Batched a source at a time:
/// one Card Variation call writes three rewordings of each of a source's
/// cards, the code's checks drop the ones too long, repeated or holding the
/// answer (`MemoryCardVariation.acceptable`), and a separate call judges the
/// rest; the rewordings that pass are stored in each card's state (its
/// Card's `variants` under generation 2, its deck's `cards.state.<deckID>`
/// row under generation 1) with the day they were made, so a card is
/// reworded once. Background spend: the pass asks before each batch — its
/// rewording call and the judge's, which only together keep a rewording —
/// and leaves the rest for the next evening once the daily cap says no.
struct CardVariationPass: Sendable {
    /// The most cards one call rewords; a source with more takes more calls.
    static let batchSize = 20

    let storage: StorageService
    let backend: any CardVariationBackend
    /// Whether background AI may spend now (`StudioViewModel.backgroundAISpendAllowed`).
    let spendAllowed: @Sendable () async -> Bool
    /// One deck's card states as stored (`MemoryCardStateStore.load`).
    let readState: @Sendable (_ deckID: String) -> MemoryCardDeckState
    /// Writes a deck's rewordings into its row.
    let write: @Sendable (_ deckID: String, _ writes: [CardVariationWrite], _ at: Date) async -> Void

    private static let logger = Logger(subsystem: "com.foreverlm", category: "CardVariation")

    /// The learner's card states on this Mac, written on the main actor
    /// (`MemoryCardStateStore.update`: the Card rows under generation 2, the
    /// synced preference rows under generation 1).
    static func live(
        storage: StorageService,
        backend: any CardVariationBackend = LiveCardVariationBackend(aiService: AIService()),
        spendAllowed: @escaping @Sendable () async -> Bool
    ) -> CardVariationPass {
        CardVariationPass(
            storage: storage,
            backend: backend,
            spendAllowed: spendAllowed,
            readState: { MemoryCardStateStore.load(deckID: $0) },
            write: { deckID, writes, now in
                await MainActor.run {
                    _ = MemoryCardStateStore.update(deckID: deckID) { row in
                        apply(writes, to: &row, at: now)
                    }
                }
                await MemoryCardStateStore.settled()
            }
        )
    }

    /// Each card's rewordings in its row: kept, its variants and the day
    /// they were made. A card that has variants already keeps them (another
    /// Mac's day close got there first).
    static func apply(_ writes: [CardVariationWrite], to row: inout MemoryCardDeckState, at now: Date) {
        for write in writes {
            var state = row.cards[write.cardID] ?? MemoryCardState(status: .kept, memoryItemID: write.itemID, updatedAt: now)
            guard state.variedAt == nil, state.variants.isEmpty else { continue }
            state.status = .kept
            state.memoryItemID = state.memoryItemID ?? write.itemID
            state.variants = write.variants
            state.variedAt = now
            state.updatedAt = now
            row.cards[write.cardID] = state
        }
    }

    func run(now: Date = Date()) async -> CardVariationReport {
        var report = CardVariationReport()
        let reviewable: (items: [MemoryItem], attempts: [MemoryAttempt])
        let keptFromAI: Set<String>
        do {
            reviewable = try await storage.memoryCardVariationItems()
            keptFromAI = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        } catch {
            report.failures.append("Cards could not be read for rewording: \(error.localizedDescription)")
            return report
        }
        // A card on a source kept from AI (the knowledge boundary) is never
        // sent to a model: it is asked in its own words.
        let items = reviewable.items.filter { item in
            !item.sources.contains { keptFromAI.contains($0.sourceID) }
        }
        var rows: [String: MemoryCardDeckState] = [:]
        let readState = readState
        let due = CardVariationCandidate.dueVariants(items: items, attempts: reviewable.attempts) { cardID, deckID in
            if rows[deckID] == nil { rows[deckID] = readState(deckID) }
            return rows[deckID]?.cards[cardID]
        }
        guard !due.isEmpty else { return report }
        guard backend.route != nil else {
            report.failures.append(CardVariationError.noModel.localizedDescription)
            return report
        }

        var order: [String] = []
        var bySource: [String: [CardVariationCandidate]] = [:]
        for card in due {
            if bySource[card.sourceID] == nil { order.append(card.sourceID) }
            bySource[card.sourceID, default: []].append(card)
        }
        var remaining = due.count
        for sourceID in order {
            let cards = bySource[sourceID] ?? []
            let source = try? await storage.loadSourceWithoutContent(sourceID)
            let title = source?.title ?? "a source"
            let usage = AIUsageSource(id: sourceID, type: source?.sourceType.rawValue ?? "unknown", title: title)
            for start in stride(from: 0, to: cards.count, by: Self.batchSize) {
                let batch = Array(cards[start..<min(start + Self.batchSize, cards.count)])
                guard await spendAllowed() else {
                    report.waiting = remaining
                    Self.logger.notice("Card variation paused at the background cap with \(remaining) card(s) waiting")
                    return report
                }
                do {
                    let writes = try await vary(batch, sourceTitle: title, usage: usage)
                    let deckByCard = Dictionary(batch.map { ($0.cardID, $0.deckID) }, uniquingKeysWith: { first, _ in first })
                    var deckOrder: [String] = []
                    var byDeck: [String: [CardVariationWrite]] = [:]
                    for change in writes {
                        guard let deckID = deckByCard[change.cardID] else { continue }
                        if byDeck[deckID] == nil { deckOrder.append(deckID) }
                        byDeck[deckID, default: []].append(change)
                    }
                    for deckID in deckOrder {
                        await write(deckID, byDeck[deckID] ?? [], now)
                    }
                    report.reworded += writes.count
                    report.varied += writes.filter { !$0.variants.isEmpty }.count
                } catch {
                    if error is CancellationError || Task.isCancelled { return report }
                    report.failures.append("Cards on \u{201C}\(title)\u{201D} could not be reworded: \(error.localizedDescription)")
                }
                remaining -= batch.count
            }
        }
        Self.logger.notice("Card variation reworded \(report.reworded) card(s), \(report.varied) with a rewording kept")
        return report
    }

    /// One batch: three rewordings a card, the code's checks, then the
    /// judge. A card left with no rewording after the checks is not judged;
    /// the judge is not called when none is left at all.
    func vary(_ batch: [CardVariationCandidate], sourceTitle: String, usage: AIUsageSource) async throws -> [CardVariationWrite] {
        let proposed = try await backend.reword(user: CardVariationTurn.rewording(batch, sourceTitle: sourceTitle), source: usage)
        let checked = CardVariationTurn.checked(proposed, cards: batch)
        var passed: [Int: [String]] = [:]
        if checked.values.contains(where: { !$0.isEmpty }) {
            try Task.checkCancellation()
            let verdicts = try await backend.judge(user: CardVariationTurn.judging(batch, rewordings: checked), source: usage)
            passed = CardVariationTurn.judged(verdicts, rewordings: checked)
        }
        // A card the model did not answer for stays as it is and is
        // reworded on another evening; one it answered for is done, with
        // whatever passed.
        return batch.enumerated().compactMap { offset, card in
            guard checked[offset + 1] != nil else { return nil }
            return CardVariationWrite(cardID: card.cardID, itemID: card.itemID, variants: passed[offset + 1] ?? [])
        }
    }
}
