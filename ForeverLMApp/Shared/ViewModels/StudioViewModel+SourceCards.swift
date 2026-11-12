import Foundation

// MARK: - Cards for every source: the Library's list
//
// docs/memory-design.md, "Cards for every source" and "A source's status:
// watered by recall" → "Where the list lives". The learner's goal is at
// least one card for each source in the library and every source worth its
// weight, so the Library's rows carry their kept cards and two verdicts under
// the pointer — Make Cards, or Not Worth Keeping — and its **No Cards** pill
// lists what still waits for one. One list: Memory has no Sources
// section of its own, which would be the same rows a second time in a bare
// title list (product owner, 2026-10-16: "probably would be better if this was integrated into
// the library tab instead?", "it needs to look nice though"). Memory keeps
// Review, To Check and All Cards; the corner card's Choose Sources opens the
// Library with the pill on.

extension StudioViewModel {

    // MARK: The read

    /// Reads every source's card coverage again when the cards or the
    /// library changed since the last read: the Library asks on each
    /// appearance and whenever `memoryCardRevision` or the sources move. One
    /// read for every window: a second asker with the same inputs waits for
    /// nothing and reads nothing. A changed coverage advances
    /// `sourceCardCoverageRevision` and invalidates the sidebar lists, so a
    /// No Cards list drops the source that just got cards.
    func refreshSourceCardCoverage() async {
        let key = "\(activeTeamID ?? "")#\(memoryCardRevision)#\(articles.count)"
        guard sourceCardCoverageKey != key else { return }
        sourceCardCoverageKey = key
        do {
            let read = try await storage.sourceCardCoverage()
            guard sourceCardCoverageKey == key else { return }
            noteSourceCardCoverage(read)
        } catch {
            // The next change asks again; the rows keep what they knew.
            if sourceCardCoverageKey == key { sourceCardCoverageKey = nil }
            logger.error("The sources' card coverage could not be read: \(error.localizedDescription)")
        }
    }

    /// Takes a coverage read as the one the Library draws (also the tests').
    func noteSourceCardCoverage(_ coverage: SourceCardCoverage) {
        guard coverage != sourceCardCoverage else { return }
        sourceCardCoverage = coverage
        sourceCardCoverageRevision &+= 1
        invalidateSidebarCachesInEveryWindow()
    }

    // MARK: The way in

    /// The Library in `windowState` with its No Cards pill on: the corner
    /// card's Choose Sources, and Memory's way to the sources
    /// (`openLibraryView` is the same Library as the rail opens it). The
    /// pill is the window's Sources list's, so the Library opens on the list
    /// the card counted and the other windows keep theirs.
    func openLibraryWithoutCards(in windowState: StudioWindowState) {
        let store = windowState.sidebarStore
        if store.sourceCardFilter != .withoutCards {
            store.sourceCardFilter = .withoutCards
            inWindow(windowState) { resetDisplayLimits() }
        }
        openLibraryView(in: windowState)
    }

    /// The Library in `windowState` on Recent, every kind newest added
    /// first: Home's "Everything you've added" under its To Read list.
    func openLibraryRecent(in windowState: StudioWindowState) {
        windowState.sidebarStore.showsRecent = true
        windowState.sidebarStore.recentDisplayLimit = 60
        openLibraryView(in: windowState)
    }

    /// The first `SourceCardList.batchSize` of `rows`, the Library's No Cards
    /// list as it stands, for the head's **Make Cards for N**: one Auto
    /// request over them gives four cards each, so the drafter can link the
    /// ideas they share. Nil with fewer than two, when the rows' own Make
    /// Cards is the way.
    static func sourceCardBatch(_ rows: [StudioArticle]) -> [String]? {
        guard rows.count > 1 else { return nil }
        return Array(rows.prefix(SourceCardList.batchSize).map(\.id))
    }
}
