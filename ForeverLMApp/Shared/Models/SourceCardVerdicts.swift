import Foundation

// MARK: - Sources and their cards: a verdict on each
//
// The learner's goal is at least one card for each piece of content in the
// library, cards that help piece the ideas together, and every piece worth
// its weight (product owner, 2026-10-16: "go through ALL the sources in my
// library and come up with at least one flashcard; and then the option to
// generate more"). The Library's rows never name a source's cards (product
// owner, 2026-11-22); a source's right-click menu carries a verdict on it: Make Cards (then Make More Cards, once
// it has some) or Not Worth Keeping, which removes it like the Sources
// list's Remove (`StudioViewModel.removeArticle`, with its Undo banner); its
// **No Cards** pill lists what still waits for one. One list, the Library's
// (product owner, 2026-10-16: "probably would be better if this was
// integrated into the library tab instead?"). The verdict stores nothing of its own: the
// cards are the "keep", the removal is the "not worth it".

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

    /// The verdict that keeps the source: the first cards, or more.
    var makeCardsTitle: String { hasCards ? "Write Another Card" : "Write Card" }
}

/// One source as the coverage lists it.
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
    /// Each listed source's state by id: what a Library row reads for its
    /// trailer. A source that is not here cannot have cards.
    private(set) var statesByID: [String: SourceCardState]

    init(rows: [SourceCardRow] = []) {
        self.rows = rows.sorted { lhs, rhs in
            if (lhs.state == .none) != (rhs.state == .none) { return lhs.state == .none }
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
            return lhs.id < rhs.id
        }
        var states: [String: SourceCardState] = [:]
        states.reserveCapacity(rows.count)
        for row in self.rows { states[row.id] = row.state }
        statesByID = states
    }

    var isEmpty: Bool { rows.isEmpty }

    func state(of sourceID: String) -> SourceCardState {
        statesByID[sourceID] ?? .none
    }

    /// Whether `sourceID` is listed and no card covers it: what the
    /// Library's No Cards pill keeps.
    func isWithoutCards(_ sourceID: String) -> Bool {
        statesByID[sourceID] == SourceCardState.none
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

/// The Library's No Cards pill: on, the list is the sources that still have
/// no card; off, everything (`StudioSidebarStore.sourceCardFilter`). Over
/// MCP, `list_source_card_coverage`'s `scope`.
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
    /// How many sources the list head's Make Cards takes together: what one
    /// Auto request can give four cards each (`MemoryCardRequestCount`), so
    /// the drafter can link their ideas.
    static let batchSize = MemoryCardRequestCount.maximumPerRequest / MemoryCardRequestCount.autoPerSource

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
