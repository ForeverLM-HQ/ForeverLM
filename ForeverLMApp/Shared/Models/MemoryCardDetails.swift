import Foundation

// MARK: - A card and its details (docs/memory-design.md, "Cards that nest")

/// One card that takes one point of another card's answer further (`memory_card_links`, the
/// overview's `Card.details`). An overview card asks for the whole (the arc of an argument, the
/// three things a paper shows); its answer is a short list, a line a point; each point can be a
/// card of its own, kept, scheduled and answered on its own, and asked at once from the overview's
/// answer ("zoom in"). A link never couples schedules and never cascades: forgetting the overview
/// deals nothing, and deleting either card leaves the other as it was.
struct MemoryCardDetailLink: Equatable, Hashable, Sendable {
    /// The overview's Card id.
    let parentID: String
    /// The detail's Card id.
    let childID: String
    /// The overview's line this detail elaborates, as it was written; empty when it elaborates the
    /// answer as a whole.
    let point: String
    /// Its place among the overview's details.
    let order: Int
    /// Cocoa seconds.
    let linkedAt: Double

    /// The most details one overview carries: an overview's answer is a short list, and a longer one
    /// is two overviews.
    static let maximumPerCard = 12

    /// The overview's details, in order.
    static func load(parentID: String, connection: SQLiteConnection) throws -> [MemoryCardDetailLink] {
        var links: [MemoryCardDetailLink] = []
        try connection.query("""
            SELECT child_id, point, sort_index, linked_at FROM memory_card_links
            WHERE parent_id = ? ORDER BY sort_index, child_id
        """, [.text(parentID)]) { row in
            guard let child = row.text(0), !child.isEmpty else { return }
            links.append(MemoryCardDetailLink(
                parentID: parentID, childID: child, point: row.text(1) ?? "",
                order: Int(row.integer(2) ?? 0), linkedAt: row.real(3) ?? 0
            ))
        }
        return links
    }
}

/// A detail as a writer names it: the card, and the overview's line it elaborates.
struct MemoryCardDetailSpec: Equatable, Hashable, Sendable {
    let childID: String
    let point: String

    init(childID: String, point: String) {
        self.childID = childID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.point = point.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a link was not made.
enum MemoryCardDetailRefusal: Equatable, Sendable {
    /// No card has that id.
    case unknownCard(String)
    /// A card cannot be its own detail.
    case itself(String)
    /// The detail already holds the overview among its own details, at some depth.
    case cycle(String)
    /// More than `MemoryCardDetailLink.maximumPerCard`.
    case tooMany

    var reason: String {
        switch self {
        case .unknownCard(let id): return "No card has the id \(id)."
        case .itself(let id): return "Card \(id) cannot be a detail of itself."
        case .cycle(let id): return "Card \(id) already holds this card among its own details."
        case .tooMany: return "A card has at most \(MemoryCardDetailLink.maximumPerCard) details; more points make two cards."
        }
    }

    var cardID: String? {
        switch self {
        case .unknownCard(let id), .itself(let id), .cycle(let id): return id
        case .tooMany: return nil
        }
    }
}

// MARK: - An overview's answer, point by point

/// An overview card's answer drawn as its points: each line of the back, and the detail card that
/// elaborates it, matched by the line's words (`MemoryCardDetailLink.point` is stored as written, and
/// a back may number or bullet its lines). A detail whose point matches no line is listed after them,
/// so every detail can be reached.
enum MemoryCardPoints {
    struct Line: Equatable, Sendable, Identifiable {
        let index: Int
        /// The line as written, Markdown and all.
        let text: String
        /// The detail that elaborates it; nil for a line no detail takes further.
        let detailID: String?
        var id: Int { index }
    }

    struct Layout: Equatable, Sendable {
        let lines: [Line]
        /// Details whose point is no line of the back, in their order.
        let unplaced: [MemoryCardDetailLink]

        var hasDetails: Bool { lines.contains { $0.detailID != nil } || !unplaced.isEmpty }
    }

    static func layout(back: String, details: [MemoryCardDetailLink]) -> Layout {
        let rawLines = back.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var remaining = details.sorted { ($0.order, $0.childID) < ($1.order, $1.childID) }
        var lines: [Line] = []
        for (index, text) in rawLines.enumerated() {
            let key = matchKey(text)
            var detailID: String?
            if !key.isEmpty, let found = remaining.firstIndex(where: { !$0.point.isEmpty && matchKey($0.point) == key }) {
                detailID = remaining.remove(at: found).childID
            }
            lines.append(Line(index: index, text: text, detailID: detailID))
        }
        return Layout(lines: lines, unplaced: remaining)
    }

    /// A line's words for matching: no list marker, no emphasis marks, case and spacing folded.
    static func matchKey(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespaces)
        if let marker = line.range(of: #"^(?:[-*•–]|\d{1,2}[.)]|\(?[a-z][.)])\s+"#, options: [.regularExpression, .caseInsensitive]) {
            line.removeSubrange(marker)
        }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        let words = line.lowercased().split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".;:,"))
    }
}
