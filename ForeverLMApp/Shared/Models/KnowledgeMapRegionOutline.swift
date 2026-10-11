import Foundation

// MARK: - The canvas menu's Regions list (docs/knowledge-map-design.md, "Adding to the canvas", part 4)
//
// Heptabase's table of contents lists a whiteboard's sections in reading
// order. The Canvas's regions nest by their rects (`parentRegionID(of:)`), so
// the list is an outline: a region, then the regions inside it, indented. The
// chrome line's canvas menu lists it, each row flying to its region.

extension KnowledgeMapLayout {
    /// One line of the Regions list.
    struct RegionOutlineRow: Equatable {
        let id: String
        /// How many regions are around it: 0 for a region inside none.
        let depth: Int
    }

    /// Every region in reading order, a region before the ones inside it:
    /// left to right inside rows one card tall, top to bottom, each level on
    /// its own, so the same plane always lists the same way.
    func regionOutline() -> [RegionOutlineRow] {
        func ordered(_ ids: [String]) -> [String] {
            func key(_ id: String) -> (Int, Double, String) {
                guard let region = regions[id] else { return (0, 0, id) }
                return (Int((region.y / KnowledgeMap.cardHeight).rounded(.down)), region.x, id)
            }
            return ids.sorted { key($0) < key($1) }
        }
        var rows: [RegionOutlineRow] = []
        var seen: Set<String> = []
        func visit(_ id: String, depth: Int) {
            guard seen.insert(id).inserted else { return }
            rows.append(RegionOutlineRow(id: id, depth: depth))
            for child in ordered(nestedRegionIDs(in: id)) { visit(child, depth: depth + 1) }
        }
        for id in ordered(regions.keys.filter { parentRegionID(of: $0) == nil }) { visit(id, depth: 0) }
        return rows
    }
}
