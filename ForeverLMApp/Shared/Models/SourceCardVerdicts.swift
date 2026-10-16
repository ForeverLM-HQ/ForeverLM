import Foundation

// MARK: - Sources and their cards: a verdict on each
//
// The learner's goal is at least one card for each piece of content in the
// library, cards that help piece the ideas together, and every piece worth
// its weight (product owner, 2026-10-16: "go through ALL the sources in my
// library and come up with at least one flashcard; and then the option to
// generate more"). The Memory pane's Sources section lists every source and
// gives each a verdict: Make Cards (then Make More Cards, once it has some)
// or Not Worth Keeping, which removes it like the Sources list's Remove
// (`StudioViewModel.removeArticle`, with its Undo banner). The verdict
// stores nothing of its own: the cards are the "keep", the removal is the
// "not worth it".

/// Where one source stands on cards.
enum SourceCardState: Equatable, Sendable {
    /// No card, kept or drafted.
    case none
    /// Drafts wait in To Check; none is kept yet.
    case toCheck
    /// This many kept cards.
    case cards(Int)
    /// Cards were made and every one is retired.
    case retired

    init(keptCards: Int, hasDrafts: Bool, isAnchored: Bool) {
        if keptCards > 0 {
            self = .cards(keptCards)
        } else if hasDrafts {
            self = .toCheck
        } else if isAnchored {
            self = .retired
        } else {
            self = .none
        }
    }

    var hasCards: Bool { self != .none }

    /// "To check", "1 card", "12 cards", "Retired"; nil with none.
    var label: String? {
        switch self {
        case .none: return nil
        case .toCheck: return "To check"
        case .cards(let count): return count == 1 ? "1 card" : "\(count) cards"
        case .retired: return "Retired"
        }
    }

    /// The verdict that keeps the source: the first cards, or more.
    var makeCardsTitle: String { hasCards ? "Make More Cards" : "Make Cards" }
}

/// One source as the section's list draws it.
struct SourceCardRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceType: StudioSourceType
    let dateAdded: Date
    let state: SourceCardState
}

/// Every source that can have cards and where each stands
/// (`StorageService.sourceCardCoverage`), the ones with no card first, then
/// the newest first.
struct SourceCardCoverage: Equatable, Sendable {
    private(set) var rows: [SourceCardRow]

    init(rows: [SourceCardRow] = []) {
        self.rows = rows.sorted { lhs, rhs in
            if (lhs.state == .none) != (rhs.state == .none) { return lhs.state == .none }
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
            return lhs.id < rhs.id
        }
    }

    func state(of sourceID: String) -> SourceCardState {
        rows.first { $0.id == sourceID }?.state ?? .none
    }

    /// The sources no card covers.
    var withoutCards: [SourceCardRow] {
        rows.filter { $0.state == .none }
    }

    /// The sources no card covers, and how many there are in all.
    var counts: (withoutCards: Int, all: Int) {
        (rows.reduce(0) { $0 + ($1.state == .none ? 1 : 0) }, rows.count)
    }
}

/// The Sources section's two lists: what still has no card, and everything.
enum SourceCardScope: String, CaseIterable, Identifiable, Sendable {
    case withoutCards
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withoutCards: return "No Cards"
        case .all: return "All"
        }
    }
}

enum SourceCardList {
    /// `rows` narrowed to `scope`, to what `query` finds in a title, to the
    /// ids in `allowed` (a notebook's sources; nil is every source) and
    /// without `removed`, which the learner has just said are not worth
    /// keeping. Order is kept.
    static func filter(
        _ rows: [SourceCardRow],
        scope: SourceCardScope,
        query: String = "",
        allowed: Set<String>? = nil,
        removed: Set<String> = []
    ) -> [SourceCardRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if removed.contains(row.id) { return false }
            if let allowed, !allowed.contains(row.id) { return false }
            if scope == .withoutCards, row.state != .none { return false }
            if !needle.isEmpty,
               row.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            return true
        }
    }
}
