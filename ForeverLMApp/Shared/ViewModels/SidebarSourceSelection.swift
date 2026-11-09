import Foundation

/// The Sources list's selection rules, kept free of AppKit so they can be tested.
///
/// The list is bound to a set of source IDs at all times. AppKit already
/// implements the platform conventions on that binding: a plain click selects
/// one row, shift-click extends a range, command-click toggles a row, and a
/// press on a row that is already part of a multi-selection leaves the
/// selection alone until mouse-up so the rows can be dragged together. These
/// rules decide what the window keeps out of each write the list makes and
/// which write also opens a source in the Reader.
///
/// Until 2026-09-07 the sidebar swapped between a single-selection list and a
/// multi-selection list on the state of the shift key, and collapsed the
/// selection to one visible row the moment shift went up. A multi-selection
/// therefore never outlived the modifier, so it could not be dragged into a
/// Notebook. Nothing here consults modifier state after the click that made the
/// selection.
enum SidebarSourceSelection {
    struct Resolution: Equatable {
        /// The rows the window keeps highlighted.
        var selection: Set<String>
        /// The source a plain click asked to read, if this write was one.
        var opensSource: String?
    }

    /// Resolves a non-empty selection the list pushed through its binding.
    ///
    /// Returns nil when nothing in the write names a source: a collection row
    /// inside a `ForEach` inherits its collection's String identity unless it
    /// supplies its own tag, and letting that presentation identity through
    /// selects the row while leaving the Reader idle.
    static func resolve(
        listSelection: Set<String>,
        previousSelection: Set<String>,
        usesMultiSelectModifier: Bool,
        isKnownSource: (String) -> Bool
    ) -> Resolution? {
        let known = listSelection.filter(isKnownSource)
        guard !known.isEmpty else { return nil }
        if usesMultiSelectModifier {
            return Resolution(selection: known, opensSource: nil)
        }
        if known.count == 1, let only = known.first {
            return Resolution(selection: known, opensSource: only)
        }
        // Without a modifier the list can only ever ask for one row, so a
        // multi-row write is either AppKit still reporting the rows it held
        // while the pointer landed on a new one, or the list echoing a
        // selection this window already holds after being rebuilt. The first
        // has exactly one new row, and that row is the click. The second adds
        // nothing and must be kept whole: collapsing it here is how a rebuilt
        // list used to throw away a multi-selection.
        let added = known.subtracting(previousSelection)
        if added.count == 1, let clicked = added.first {
            return Resolution(selection: [clicked], opensSource: clicked)
        }
        return Resolution(selection: known, opensSource: nil)
    }

    /// The sources a drag that starts on `sourceID` carries.
    ///
    /// A row inside a multi-selection drags the whole selection in display
    /// order. Any other row drags alone; AppKit has already made it the
    /// selection on mouse-down, as the platform does everywhere.
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
    /// The row's own tap gesture fires on mouse-up after the list has already
    /// written the selection, so it can see what that click did: a click that
    /// left the row inside a multi-selection was a shift-click extending it, and
    /// a click made with the modifier still down was a toggle either way. Both
    /// are selection, not navigation.
    static func rowTapOpens(
        sourceID: String,
        selection: Set<String>,
        usesMultiSelectModifier: Bool
    ) -> Bool {
        if usesMultiSelectModifier { return false }
        return !(selection.count > 1 && selection.contains(sourceID))
    }

    // MARK: The lazy list's own clicks and keys

    /// What a ⌘- or ⇧-click does in a list that keeps its own selection rather
    /// than AppKit's (the Papers tab's lazy list, `SourcesLazyList`): ⌘
    /// toggles the row, ⇧ selects the run from `anchor` to the row in display
    /// order, as Finder does. A plain click is the row's open
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
