import Foundation

// MARK: - A card's details over MCP (docs/memory-design.md, "Cards that nest")
//
// An overview card asks for the whole (the arc of an argument); its back is a short list, a line a
// point, and each point can be a card of its own, its detail. `save_card_drafts` saves an overview
// and its details in one call (`ref`, `detail_of`, `point`), `set_card_details` links or unlinks
// cards that exist, and `list_cards` and `get_due_cards` say which cards are which. Links are free:
// no model is called.

extension MCPDataStore {
    /// One card of a `save_card_drafts` call that names an overview: the card it is (by its index in
    /// the call), what it named, and the line it elaborates.
    struct CardDetailRequest {
        let index: Int
        let front: String
        let detailOf: String
        let point: String
    }

    /// Reads `ref`, `detail_of` and `point` off a `save_card_drafts` card. A `point` without
    /// `detail_of` means nothing and is refused, as is a `ref` used twice.
    static func cardDetailRequest(_ entry: [String: Any], index: Int, front: String) throws -> CardDetailRequest? {
        let detailOf = trimmedOrNil(entry["detail_of"] as? String)
        let point = trimmedOrNil(entry["point"] as? String) ?? ""
        guard let detailOf else {
            guard point.isEmpty else {
                throw MCPError.invalidInput("Nothing was saved. Card \(index) has a point but no detail_of: name the card whose answer it takes further.")
            }
            return nil
        }
        return CardDetailRequest(index: index, front: front, detailOf: detailOf, point: point)
    }

    /// The `ref` each card of a call gives itself, by index; refused when two cards share one.
    static func cardRefs(_ rawCards: [[String: Any]]) throws -> [String: Int] {
        var refs: [String: Int] = [:]
        for (index, entry) in rawCards.enumerated() {
            guard let ref = trimmedOrNil(entry["ref"] as? String) else { continue }
            guard refs[ref] == nil else {
                throw MCPError.invalidInput("Nothing was saved. Two cards share the ref \(ref); give each card its own.")
            }
            refs[ref] = index
        }
        return refs
    }

    /// Links the details a `save_card_drafts` call named, once its cards are saved: each overview
    /// keeps the details it had and takes the new ones after them, in the call's order. `savedIDs`
    /// is each saved card's id by its index in the call. Returns the payload's `details_linked` and
    /// `details_not_linked`.
    func linkSavedCardDetails(
        _ requests: [CardDetailRequest],
        refs: [String: Int],
        savedIDs: [Int: String]
    ) async -> (linked: [[String: Any]], notLinked: [[String: Any]]) {
        var notLinked: [[String: Any]] = []
        var byParent: [(parent: String, details: [MemoryCardDetailSpec])] = []
        for request in requests {
            guard let child = savedIDs[request.index] else {
                notLinked.append(["front": request.front, "detail_of": request.detailOf, "reason": "This card was not saved, so it is no detail yet."])
                continue
            }
            let parent: String
            if let index = refs[request.detailOf] {
                guard let saved = savedIDs[index] else {
                    notLinked.append(["front": request.front, "detail_of": request.detailOf, "reason": "The card with that ref was not saved."])
                    continue
                }
                parent = saved
            } else {
                parent = request.detailOf
            }
            let spec = MemoryCardDetailSpec(childID: child, point: request.point)
            if let at = byParent.firstIndex(where: { $0.parent == parent }) {
                byParent[at].details.append(spec)
            } else {
                byParent.append((parent, [spec]))
            }
        }
        var linked: [[String: Any]] = []
        for (parent, added) in byParent {
            do {
                guard let overview = try await notebookFileStorage.cardRecordID(naming: parent) else {
                    for spec in added {
                        notLinked.append(["card_id": spec.childID, "detail_of": parent, "reason": "No card has the id \(parent); detail_of takes a ref of this call or a card_id from list_cards."])
                    }
                    continue
                }
                let held = try await notebookFileStorage.cardDetails(ofParents: [overview])[overview] ?? []
                let kept = held.filter { link in !added.contains { $0.childID == link.childID } }
                    .map { MemoryCardDetailSpec(childID: $0.childID, point: $0.point) }
                let result = try await notebookFileStorage.setCardDetails(parentID: overview, kept + added)
                for refusal in result.refused {
                    notLinked.append(["card_id": refusal.cardID ?? "", "detail_of": overview, "reason": refusal.reason])
                }
                linked.append(["card_id": overview, "details": result.linked.map(Self.cardDetailPayload)])
            } catch {
                for spec in added {
                    notLinked.append(["card_id": spec.childID, "detail_of": parent, "reason": error.localizedDescription])
                }
            }
        }
        return (linked, notLinked)
    }

    static func cardDetailPayload(_ link: MemoryCardDetailLink) -> [String: Any] {
        ["card_id": link.childID, "point": link.point]
    }

    /// `details` and `detail_of` for the cards a list names, by the ids it names them by (a card's
    /// own id first, then its item's): only what a card has.
    func cardLinksPayload(ids: [[String]], store: KnowledgeStore) throws -> [String: [String: Any]] {
        let all = Array(Set(ids.flatMap { $0 }))
        let details = try store.cardDetails(ofParents: all)
        let overviews = try store.cardOverviews(ofChildren: all)
        guard !details.isEmpty || !overviews.isEmpty else { return [:] }
        var result: [String: [String: Any]] = [:]
        for names in ids {
            guard let key = names.first else { continue }
            var entry: [String: Any] = [:]
            if let links = names.lazy.compactMap({ details[$0] }).first {
                entry["details"] = links.map(Self.cardDetailPayload)
            }
            if let links = names.lazy.compactMap({ overviews[$0] }).first {
                entry["detail_of"] = links.map { ["card_id": $0.parentID, "point": $0.point] }
            }
            if !entry.isEmpty { result[key] = entry }
        }
        return result
    }

    // MARK: set_card_details

    /// Sets which cards take each point of a card's answer further, in order: `details` replaces the
    /// card's list ([] unlinks them all). Free, and no Start Over: neither card's face, anchors or
    /// schedule change. Kept cards and cards to check alike.
    func setCardDetails(cardID rawCardID: String?, details rawDetails: Any?) async throws -> String {
        guard let cardID = Self.trimmedOrNil(rawCardID) else {
            throw MCPError.invalidInput("card_id is required: the overview card, as list_cards returns it.")
        }
        guard let entries = rawDetails as? [Any] else {
            throw MCPError.invalidInput("details is required: a list of {card_id, point}, in order; [] unlinks them all.")
        }
        var specs: [MemoryCardDetailSpec] = []
        for (index, raw) in entries.enumerated() {
            guard let object = raw as? [String: Any], let child = Self.trimmedOrNil(object["card_id"] as? String) else {
                throw MCPError.invalidInput("Nothing was changed. details[\(index)] needs a card_id.")
            }
            specs.append(MemoryCardDetailSpec(childID: child, point: (object["point"] as? String) ?? ""))
        }
        guard let overview = try await notebookFileStorage.cardRecordID(naming: cardID) else {
            throw MCPError.invalidInput("No card has the id \(cardID). Pass a card_id (or item_id) from list_cards.")
        }
        let result = try await notebookFileStorage.setCardDetails(parentID: overview, specs)
        if result.refused.contains(.tooMany) {
            throw MCPError.invalidInput("Nothing was changed. \(MemoryCardDetailRefusal.tooMany.reason)")
        }
        var payload: [String: Any] = [
            "card_id": overview,
            "details": result.linked.map(Self.cardDetailPayload),
            "message": result.linked.isEmpty
                ? "The card has no details now."
                : "The card's answer now leads to \(result.linked.count) detail\(result.linked.count == 1 ? "" : "s"). In review, each linked point of its answer asks its card at once.",
        ]
        if !result.refused.isEmpty {
            payload["not_linked"] = result.refused.map { ["card_id": $0.cardID ?? "", "reason": $0.reason] }
        }
        return try jsonString(payload)
    }
}
