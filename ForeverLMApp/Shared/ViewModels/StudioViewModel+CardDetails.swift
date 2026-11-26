import Foundation

// MARK: - A card's details in the card review (docs/memory-design.md, "Cards that nest")

extension StudioViewModel {
    /// The card review's read of its cards' links (`MemoryCardSessionModel.CardLinksStep`).
    func memoryCardLinksStep() -> MemoryCardSessionModel.CardLinksStep {
        { [weak self] cards in
            guard let self else { return [:] }
            return try await self.memoryCardLinks(for: cards)
        }
    }

    /// The links of a sitting's cards, by `MemoryCardSitting.Card.recordID`: each overview's details
    /// as cards the review can ask (a kept detail as the review deals it, one still to check as a
    /// notebook's Practice deals a draft, so answering it keeps it), and each detail's overviews by
    /// their fronts. A link whose card is retired, gone or on a source the library no longer shows is
    /// left out. When no card has a link nothing more is read.
    func memoryCardLinks(for cards: [MemoryCardSitting.Card]) async throws -> [String: MemoryCardSessionModel.CardLinks] {
        let ids = cards.map(\.recordID)
        let details = try await storage.cardDetails(ofParents: ids)
        let overviews = try await storage.cardOverviews(ofChildren: ids)
        guard !details.isEmpty || !overviews.isEmpty else { return [:] }
        let wanted = Set(details.values.flatMap { $0.map(\.childID) } + overviews.values.flatMap { $0.map(\.parentID) })
        let found = try await memorySittingCards(recordIDs: Array(wanted).sorted())
        var result: [String: MemoryCardSessionModel.CardLinks] = [:]
        for (parent, links) in details {
            result[parent, default: MemoryCardSessionModel.CardLinks()].details = links.compactMap { link in
                found[link.childID].map { MemoryCardSessionModel.Detail(link: link, card: $0) }
            }
        }
        for (child, links) in overviews {
            result[child, default: MemoryCardSessionModel.CardLinks()].overviewFronts = links.compactMap {
                found[$0.parentID].map { CardVisualization.words($0.front) }
            }
        }
        return result
    }

    /// Cards by Card record id, as the review deals them: kept ones through the chosen cards' read
    /// (`memoryCardChosenPractice`), the rest from the cards to check.
    private func memorySittingCards(recordIDs: [String]) async throws -> [String: MemoryCardSitting.Card] {
        guard !recordIDs.isEmpty else { return [:] }
        let deal = try await storage.memoryCardChosenPractice(cardIDs: recordIDs, now: Date())
        var found: [String: MemoryCardSitting.Card] = [:]
        let kept = memorySittingCards(deal.kept.answerable, attemptsByItemID: deal.attemptsByItemID)
            + memorySittingCards(deal.kept.notDueYet, attemptsByItemID: deal.attemptsByItemID)
        for card in kept { found[card.recordID] = card }
        let missing = Set(recordIDs).subtracting(found.keys)
        guard !missing.isEmpty else { return found }
        let snapshot = try await memoryCardReviewSnapshot(scope: .allNotebooks, includesListings: false, includesToCheck: true)
        for draft in snapshot.toCheck where missing.contains(draft.id) {
            if let card = MemoryCardSitting.Card.draft(draft) { found[draft.id] = card }
        }
        return found
    }
}
