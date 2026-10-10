import Foundation

// MARK: - Memory on the Canvas: the reads (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// One read of the kept cards — the one the Memory pane's All Cards and the
// card review's snapshot make (`reviewableMemoryItems`: active, outside any
// sync conflict, anchored only on sources the library shows, screen record
// mode's scope applied) — narrowed to the cards anchored on some sources.
// Under generation 2 the items and their answers are what the Card and
// Sitting records project, so the marks and the deal read what every device
// wrote. Reading writes nothing.

/// The kept cards with a face anchored on some sources, and their whole
/// answer histories.
struct CanvasMemoryRead: Sendable {
    let items: [MemoryItem]
    let attempts: [MemoryAttempt]

    static let empty = CanvasMemoryRead(items: [], attempts: [])
}

extension KnowledgeStore {
    /// The kept cards anchored on any of `sourceIDs` (every kept card when
    /// nil), as the card review reads them: only an item with a face is a
    /// card (`MemoryCard.face`).
    func canvasMemoryRead(anchoredOn sourceIDs: Set<String>?) throws -> CanvasMemoryRead {
        if let sourceIDs, sourceIDs.isEmpty { return .empty }
        let reviewable = try reviewableMemoryItems()
        let attemptsByItemID = Dictionary(grouping: reviewable.attempts, by: \.memoryItemID)
        let items = reviewable.items.filter { item in
            if let sourceIDs, sourceIDs.isDisjoint(with: item.sources.map(\.sourceID)) { return false }
            return MemoryCard.face(of: item, attempts: attemptsByItemID[item.id] ?? []) != nil
        }
        let ids = Set(items.map(\.id))
        return CanvasMemoryRead(items: items, attempts: reviewable.attempts.filter { ids.contains($0.memoryItemID) })
    }
}

extension StorageService {
    func canvasMemoryRead(anchoredOn sourceIDs: Set<String>?) throws -> CanvasMemoryRead {
        try notebookFilesKnowledgeStore().canvasMemoryRead(anchoredOn: sourceIDs)
    }

    /// One mark per key over the kept cards anchored on the key's sources
    /// (`CanvasMemoryMarks.marks`), read and counted here, off the main
    /// actor, in one read for every key.
    func canvasMemoryMarks(
        for groups: [String: Set<String>],
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [String: KnowledgeMapMemoryMark] {
        guard !groups.isEmpty else { return [:] }
        let wanted = groups.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let read = try canvasMemoryRead(anchoredOn: wanted)
        let cards = CanvasMemoryCard.cards(items: read.items, attempts: read.attempts, calendar: calendar)
        return CanvasMemoryMarks.marks(for: groups, cards: cards, now: now)
    }

    /// A source's stored text, as `saveCardDrafts` grounds a card's quote
    /// against it (and `get_source_content` answers with): the passages a
    /// situated card may quote are cut from it, so a quote copied from one
    /// is found there again. Nil for a source with no text.
    func situatedSourceText(_ sourceID: String) throws -> String? {
        let text = try notebookFilesKnowledgeStore().loadSourceContent(sourceID)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
