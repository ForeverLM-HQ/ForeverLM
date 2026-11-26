import SwiftUI

// MARK: - An overview's answer, point by point (docs/memory-design.md, "Cards that nest")

/// The back of a card that has details (the arc of an argument, a step a line): each line as the
/// card wrote it, and a line a detail takes further is a button that asks that detail now ("zoom
/// in", `MemoryCardSessionModel.zoomIn`). A detail whose point is no line of the back follows the
/// lines, under its point or its own question. A back holding a table is drawn whole, its details
/// under it.
struct MemoryCardPointsView: View {
    let back: String
    let details: [MemoryCardSessionModel.Detail]
    let zoom: (MemoryCardSessionModel.Detail) -> Void

    var body: some View {
        let holdsTable = CardFaceMarkdown.blocks(back).contains {
            if case .table = $0 { return true }
            return false
        }
        let links = details.map(\.link)
        let layout = holdsTable
            ? MemoryCardPoints.Layout(lines: [], unplaced: links.sorted { ($0.order, $0.childID) < ($1.order, $1.childID) })
            : MemoryCardPoints.layout(back: back, details: links)
        let byID = Dictionary(details.map { ($0.link.childID, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 8) {
            if holdsTable {
                CardFaceText(back)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(layout.lines) { line in
                if let id = line.detailID, let detail = byID[id] {
                    pointButton(line.text, detail)
                } else {
                    Text(line.text.cardFaceText())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(layout.unplaced, id: \.childID) { link in
                if let detail = byID[link.childID] {
                    pointButton(link.point.isEmpty ? CardVisualization.words(detail.card.front) : link.point, detail)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory.cards.points")
    }

    private func pointButton(_ text: String, _ detail: MemoryCardSessionModel.Detail) -> some View {
        Button {
            zoom(detail)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text.cardFaceText())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
        .help("Ask this point now: \(CardVisualization.words(detail.card.front))")
        .accessibilityLabel(CardVisualization.words(text))
        .accessibilityHint("Asks this point's own card now")
        .accessibilityIdentifier("memory.cards.point")
    }
}

/// Over a detail asked from its overview's answer: the way back to the whole, without answering
/// the detail (`MemoryCardSessionModel.zoomOut`).
struct MemoryCardZoomBar: View {
    let overviewFront: String
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text(CardVisualization.words(overviewFront).cardPlainText())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: -5))
        .help("Back to the whole card without answering this one")
        .accessibilityLabel("Back to the whole card")
        .accessibilityIdentifier("memory.cards.zoomOut")
    }
}

/// Under a detail's answer when the review dealt it on its own: the overview it belongs to.
struct MemoryCardPartOfLine: View {
    let fronts: [String]

    var body: some View {
        Text("Part of: " + fronts.map { $0.cardPlainText() }.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
            .accessibilityIdentifier("memory.cards.partOf")
    }
}
