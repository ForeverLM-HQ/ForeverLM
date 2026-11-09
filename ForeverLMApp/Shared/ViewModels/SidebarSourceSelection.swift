import Foundation

/// The Sources list's selection rules, kept free of AppKit so they can be tested.
///
/// The list (`StudioSidebar`'s lazy list) keeps a set of source IDs selected
/// and follows the Mac's conventions on it: a plain click selects one row and
/// opens it, ⇧-click selects a run, ⌘-click toggles a row, ↑ ↓ move, and a
/// multi-selection stays whole until a plain click or Escape, so its rows can
/// be dragged together.
enum SidebarSourceSelection {
    /// The sources a drag that starts on `sourceID` carries.
    ///
    /// A row inside a multi-selection drags the whole selection in display
    /// order. Any other row drags alone.
    static func dragSourceIDs(
        startingWith sourceID: String,
        selection: Set<String>,
        displayOrder: (Set<String>) -> [String]
    ) -> [String] {
        guard selection.count > 1, selection.contains(sourceID) else { return [sourceID] }
        let ordered = displayOrder(selection)
        return ordered.isEmpty ? [sourceID] : ordered
    }

    /// Whether the row gesture that ended on `sourceID` should open it.
    ///
    /// A click made with ⇧ or ⌘ down is selection, not navigation, and so is a
    /// tap on a row still inside a multi-selection.
    static func rowTapOpens(
        sourceID: String,
        selection: Set<String>,
        usesMultiSelectModifier: Bool
    ) -> Bool {
        if usesMultiSelectModifier { return false }
        return !(selection.count > 1 && selection.contains(sourceID))
    }

    // MARK: Clicks and keys

    /// What a ⌘- or ⇧-click does: ⌘ toggles the row, ⇧ selects the run from
    /// `anchor` to the row in display order, as Finder does. A plain click is the row's open
    /// (`openSidebarArticle`), which selects it alone.
    static func selectionAfterModifiedClick(
        on sourceID: String,
        selection: Set<String>,
        anchor: String?,
        displayOrder: [String],
        command: Bool
    ) -> Set<String> {
        if command {
            var toggled = selection
            if toggled.contains(sourceID) { toggled.remove(sourceID) } else { toggled.insert(sourceID) }
            return toggled
        }
        return range(from: anchor, to: sourceID, in: displayOrder)
    }

    /// The rows from `anchor` to `sourceID`, both included, in display order;
    /// the row alone when the anchor is gone from the list.
    static func range(from anchor: String?, to sourceID: String, in displayOrder: [String]) -> Set<String> {
        guard let anchor,
              let start = displayOrder.firstIndex(of: anchor),
              let end = displayOrder.firstIndex(of: sourceID) else { return [sourceID] }
        return Set(displayOrder[min(start, end)...max(start, end)])
    }

    /// The row ↑ or ↓ moves to from `current`: the first row (↓) or the last
    /// (↑) when nothing is current, and nil at either end, where the key does
    /// nothing.
    static func rowAfterArrow(from current: String?, in displayOrder: [String], down: Bool) -> String? {
        guard let current, let index = displayOrder.firstIndex(of: current) else {
            return down ? displayOrder.first : displayOrder.last
        }
        let next = down ? index + 1 : index - 1
        return displayOrder.indices.contains(next) ? displayOrder[next] : nil
    }

    /// The selection Escape leaves behind, or nil when Escape has nothing to
    /// do here and should travel on to whatever else is listening for it.
    ///
    /// A multi-selection is the only state a click cannot leave without also
    /// opening something, so Escape collapses it to the source the Reader
    /// shows, or to nothing when the Reader is closed.
    static func selectionAfterEscape(
        selection: Set<String>,
        readerSourceID: String?
    ) -> Set<String>? {
        guard selection.count > 1 else { return nil }
        if let readerSourceID, selection.contains(readerSourceID) {
            return [readerSourceID]
        }
        return []
    }
}
