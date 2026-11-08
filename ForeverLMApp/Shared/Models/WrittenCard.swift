import Foundation

// MARK: - Cards the learner writes
//
// docs/memory-design.md, "Writing a source's card". A source is processed
// once it has a card, and that card is the learner's to write (product
// owner, 2026-11-08: "the goal should still be that I myself go through
// this newly added sources and kind of make the card myself. That's kind
// of desirable difficulty. It shouldn't just be AI making those cards").
// Make Cards in the Library, the Reader, a notebook's Cards tile and the
// morning banner opens the source with a blank card beside it: the learner
// writes the question and the answer in their own words and picks the
// passage it stands on by selecting it in the Reader. Save keeps the card
// at once — there is nothing to check, the learner wrote it — and no model
// is called. Drafting by a model stays a chat request the learner types.

/// One sitting of writing cards: the sources the learner asked to write
/// for, in order, and where they are. Held by the window
/// (`StudioWindowState.cardWriting`); the Memory pane draws it.
struct CardWritingSession: Equatable, Sendable {
    /// The sources, in the order Make Cards listed them, at least one.
    let sourceIDs: [String]
    /// The notebook the sources were chosen in, when there was one.
    let notebookID: String?
    private(set) var index: Int = 0
    /// Cards saved in this sitting, by source id.
    private(set) var savedBySource: [String: Int] = [:]

    init?(sourceIDs: [String], notebookID: String?) {
        var seen = Set<String>()
        let ids = sourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        self.sourceIDs = ids
        self.notebookID = notebookID
    }

    var sourceID: String { sourceIDs[index] }
    var position: Int { index + 1 }
    var count: Int { sourceIDs.count }
    var isLast: Bool { index == sourceIDs.count - 1 }
    var savedHere: Int { savedBySource[sourceID] ?? 0 }
    var savedInAll: Int { savedBySource.values.reduce(0, +) }

    /// "2 of 10" while there is more than one source; nil for one.
    var progressLabel: String? {
        count > 1 ? "\(position) of \(count)" : nil
    }

    mutating func noteSaved() {
        savedBySource[sourceID, default: 0] += 1
    }

    /// Moves to the next source; false on the last, which stays.
    @discardableResult
    mutating func advance() -> Bool {
        guard !isLast else { return false }
        index += 1
        return true
    }
}

/// What the learner has written on the card beside the source.
struct WrittenCardInput: Equatable, Sendable {
    var front = ""
    var back = ""
    /// The passage the card stands on, taken from the Reader's selection.
    var passage = ""

    enum Missing: Equatable, Sendable {
        case front, back, passage

        /// What the Save button's help says is still to do.
        var help: String {
            switch self {
            case .front: return "Write the question"
            case .back: return "Write the answer in your own words"
            case .passage: return "Select the passage it stands on in the source, then Use Selection"
            }
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first thing the card still needs, in the order it is written;
    /// nil when it can be saved.
    var missing: Missing? {
        if Self.trimmed(front).isEmpty { return .front }
        if Self.trimmed(back).isEmpty { return .back }
        if Self.trimmed(passage).isEmpty { return .passage }
        return nil
    }

    var isEmpty: Bool {
        Self.trimmed(front).isEmpty && Self.trimmed(back).isEmpty && Self.trimmed(passage).isEmpty
    }

    /// The card it keeps, under a new card id: the learner's words as they
    /// wrote them, trimmed (`MemoryCard.init`). Nil while something is
    /// missing.
    func card(id: String = UUID().uuidString) -> MemoryCard? {
        guard missing == nil else { return nil }
        return MemoryCard(cardID: id, front: front, back: back, origin: .manual)
    }

    /// A Reader selection as the card's passage: its words on one line, as
    /// a kept card's quote is stored. Nil for a selection with no words.
    static func passage(fromSelection text: String) -> String? {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return words.isEmpty ? nil : words
    }
}
