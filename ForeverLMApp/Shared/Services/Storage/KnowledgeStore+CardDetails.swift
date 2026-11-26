import Foundation

// MARK: - A card's details (`memory_card_links`, `Card.details`; docs/memory-design.md "Cards that nest")

extension KnowledgeStore {
    /// The Card id a writer's `id` names: a card's own id (a draft's, or a kept card's, which is its
    /// Memory item's) as it is, or a drafted card's id whose item is `MemoryTutorIdentity.cardItemID`
    /// of it, as `list_cards` and `practice_cards` take either. Nil when no card has it.
    func cardRecordID(naming id: String) throws -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if try cardExists(id) { return id }
        let item = MemoryTutorIdentity.cardItemID(cardID: id)
        return try cardExists(item) ? item : nil
    }

    private func cardExists(_ id: String) throws -> Bool {
        try scalarInteger("""
            SELECT EXISTS(SELECT 1 FROM memory_card_states WHERE card_id = ?1)
                OR EXISTS(SELECT 1 FROM memory_items WHERE id = ?1)
        """, [.text(id)]) == 1
    }

    /// Each overview's details, in order, for the overviews `parentIDs` names (only those with any).
    func cardDetails(ofParents parentIDs: [String]) throws -> [String: [MemoryCardDetailLink]] {
        var result: [String: [MemoryCardDetailLink]] = [:]
        for parent in Set(parentIDs) where !parent.isEmpty {
            let links = try MemoryCardDetailLink.load(parentID: parent, connection: self)
            if !links.isEmpty { result[parent] = links }
        }
        return result
    }

    /// The overviews each of `childIDs` is a detail of (only those that are one), by detail.
    func cardOverviews(ofChildren childIDs: [String]) throws -> [String: [MemoryCardDetailLink]] {
        var result: [String: [MemoryCardDetailLink]] = [:]
        for child in Set(childIDs) where !child.isEmpty {
            try query("""
                SELECT parent_id, point, sort_index, linked_at FROM memory_card_links
                WHERE child_id = ? ORDER BY linked_at, parent_id
            """, [.text(child)]) { row in
                guard let parent = row.text(0), !parent.isEmpty else { return }
                result[child, default: []].append(MemoryCardDetailLink(
                    parentID: parent, childID: child, point: row.text(1) ?? "",
                    order: Int(row.integer(2) ?? 0), linkedAt: row.real(3) ?? 0
                ))
            }
        }
        return result
    }

    /// Every card above `id`: its overviews, theirs, and so on.
    private func cardAncestors(of id: String) throws -> Set<String> {
        var seen = Set<String>()
        var frontier = [id]
        while let next = frontier.popLast() {
            try query("SELECT parent_id FROM memory_card_links WHERE child_id = ?", [.text(next)]) { row in
                if let parent = row.text(0), seen.insert(parent).inserted { frontier.append(parent) }
            }
        }
        return seen
    }

    /// Sets the overview `parentID`'s details to `details`, in that order: a detail it no longer lists
    /// is unlinked, one it already had keeps when it was linked and takes its new point and place, a new
    /// one is linked now. Every id is resolved first (`cardRecordID(naming:)`); nothing is written when
    /// the overview is unknown or there are too many details, and a detail that is unknown, the overview
    /// itself, or one that already holds the overview below it is left out and returned refused. Through
    /// the outbox triggers, so the overview's record carries the change. Not a Start Over: neither card's
    /// face or anchors change.
    @discardableResult
    func setCardDetails(
        parentID: String,
        _ details: [MemoryCardDetailSpec],
        at now: Date = Date()
    ) throws -> (linked: [MemoryCardDetailLink], refused: [MemoryCardDetailRefusal]) {
        guard let parent = try cardRecordID(naming: parentID) else {
            throw MemoryCardError.notFound(parentID)
        }
        guard details.count <= MemoryCardDetailLink.maximumPerCard else {
            return ([], [.tooMany])
        }
        let ancestors = try cardAncestors(of: parent)
        var refused: [MemoryCardDetailRefusal] = []
        var wanted: [(child: String, point: String)] = []
        var seen = Set<String>()
        for spec in details {
            guard let child = try cardRecordID(naming: spec.childID) else {
                refused.append(.unknownCard(spec.childID)); continue
            }
            guard child != parent else { refused.append(.itself(spec.childID)); continue }
            guard !ancestors.contains(child) else { refused.append(.cycle(spec.childID)); continue }
            if seen.insert(child).inserted { wanted.append((child, spec.point)) }
        }
        let held = Dictionary(
            try MemoryCardDetailLink.load(parentID: parent, connection: self).map { ($0.childID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        try exec("BEGIN IMMEDIATE")
        do {
            for child in held.keys where !wanted.contains(where: { $0.child == child }) {
                try execute("DELETE FROM memory_card_links WHERE parent_id = ? AND child_id = ?", [.text(parent), .text(child)])
            }
            for (index, detail) in wanted.enumerated() {
                let linkedAt = held[detail.child]?.linkedAt ?? now.timeIntervalSinceReferenceDate
                try execute("""
                    INSERT INTO memory_card_links (parent_id, child_id, point, sort_index, linked_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(parent_id, child_id) DO UPDATE SET point = excluded.point, sort_index = excluded.sort_index
                    WHERE memory_card_links.point <> excluded.point OR memory_card_links.sort_index <> excluded.sort_index
                """, [.text(parent), .text(detail.child), .text(detail.point), .integer(Int64(index)), .real(linkedAt)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return (try MemoryCardDetailLink.load(parentID: parent, connection: self), refused)
    }

    /// A card started over takes the old card's place in every link, as overview and as detail, so an
    /// argument keeps its steps whichever of its cards is reworded (`recordCardRecordStartOver`). Runs
    /// inside the caller's transaction.
    func moveCardLinks(from oldID: String, to newID: String) throws {
        guard oldID != newID else { return }
        try execute("""
            INSERT INTO memory_card_links (parent_id, child_id, point, sort_index, linked_at)
            SELECT ?2, child_id, point, sort_index, linked_at FROM memory_card_links WHERE parent_id = ?1 AND child_id <> ?2
            ON CONFLICT(parent_id, child_id) DO NOTHING
        """, [.text(oldID), .text(newID)])
        try execute("""
            INSERT INTO memory_card_links (parent_id, child_id, point, sort_index, linked_at)
            SELECT parent_id, ?2, point, sort_index, linked_at FROM memory_card_links WHERE child_id = ?1 AND parent_id <> ?2
            ON CONFLICT(parent_id, child_id) DO NOTHING
        """, [.text(oldID), .text(newID)])
        try execute("DELETE FROM memory_card_links WHERE parent_id = ?1 OR child_id = ?1", [.text(oldID)])
    }
}
