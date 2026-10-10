import Foundation

/// A normalized rectangle measured from the top-left of a rendered PDF page.
/// Values are validated before persistence so UI renderers never receive a
/// negative or off-page crop from a model response.
struct PaperFigureRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.001 && y + height <= 1.001
    }
}

struct PaperFigurePanel: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let explanation: String
    let rect: PaperFigureRect?
}

struct PaperFigureAnalysis: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let summary: String
    let visualEvidence: [String]
    let figureRect: PaperFigureRect?
    let panels: [PaperFigurePanel]
    let analysisVersion: Int
    let generatedAt: Date
}

/// Which of a paper's figures a canvas lays out, and in what order
/// (docs/knowledge-map-design.md, "Figures only"). The product owner, 2026-10-09: *"a
/// 'figure only mode' where I can choose to only show the figures on the
/// canvas; then maybe extended figures also optionally"*.
enum PaperFigureSelection {
    /// Whether a figure's printed label names an extended or supplementary
    /// figure rather than a main one: "Extended Data Fig. 1", "ED Fig. 2",
    /// "Supplementary Figure 3", "Supplemental Fig. S4", "Figure S1", "Fig.
    /// S2", "S3", "Appendix Figure 1".
    static func isExtended(_ label: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return false }
        let prefixes = ["extended data", "extended fig", "ed fig", "ed.fig", "supplementary", "supplemental", "suppl", "appendix fig", "appendix figure"]
        if prefixes.contains(where: { text.hasPrefix($0) }) { return true }
        // "Figure S1", "Fig. S2", "Fig S3", "S4".
        let pattern = #"^(?:fig(?:ure)?\.?\s*)?s\s?\d"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The first number in a label ("Figure 12" → 12, "Fig. S3" → 3); nil
    /// for a label with none.
    static func number(in label: String) -> Int? {
        guard let range = label.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(label[range])
    }

    /// The figures to lay out, in print order: the main figures by number
    /// then page, and after them the extended and supplementary figures when
    /// `includeExtended`. `label` and `pageIndex` read each item, so the
    /// store's records and a test's tuples order the same way.
    static func ordered<Item>(
        _ items: [Item],
        includeExtended: Bool,
        label: (Item) -> String,
        pageIndex: (Item) -> Int
    ) -> [Item] {
        func key(_ item: Item) -> (Int, Int, String) {
            (number(in: label(item)) ?? Int.max, pageIndex(item), label(item).lowercased())
        }
        let main = items.filter { !isExtended(label($0)) }.sorted { key($0) < key($1) }
        guard includeExtended else { return main }
        let extended = items.filter { isExtended(label($0)) }.sorted { key($0) < key($1) }
        return main + extended
    }
}

/// The portable part of a paper figure. No local file path is synced: the phone
/// and Mac render this page from the source's existing PDF asset.
struct SyncedPaperFigure: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sourceID: String
    let figureLabel: String
    let pageIndex: Int
    let caption: String
    let analysis: PaperFigureAnalysis?

    var pageNumber: Int { pageIndex + 1 }
}
