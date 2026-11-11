import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The Space and the notebooks home.
    enum Space {
        /// The Space (docs/docs-design.md, "The Space"): what this Mac opened
        /// last, which opening a page must not make travel, and how this Mac's
        /// screen draws the lists and the sidebar.
        static let recents = DeviceKey<[Any]?>("space.recents.v1", coding: .array, reason: "device-local: the Space sidebar's Recents on this Mac")
        static let layout = DeviceKey<String?>("space.layout", reason: "device-local: List or Grid in this Mac's Space")
        static let sort = DeviceKey<String?>("space.sort", reason: "device-local: the sort in this Mac's Space")
        static let groupByCollection = DeviceKey<Bool>("space.groupByCollection", default: false, reason: "device-local: whether this Mac's Space groups All under its collections")
        static let sidebarHidden = DeviceKey<Bool>("space.sidebarHidden", default: false, reason: "device-local: whether this Mac's Space sidebar is hidden")
        static let pagesExpanded = DeviceKey<String>("space.pagesExpanded", default: "", reason: "device-local: which pages' subpages this Mac's Space lists show")
        static let boardLens = DeviceKey<String>("space.boardLens", default: "all", reason: "which lens this Mac's Board shows")
        static let sidebarRecentsFolded = DeviceKey<Bool>("space.sidebar.recentsFolded", default: false, reason: "whether this Mac's Space sidebar folds its Recents")
        /// How the iPhone's and iPad's Home draws and orders the notebooks:
        /// Grid or List, the sort and its direction. The view of the catalog on
        /// that device's screen. The Mac's Notebooks home, which read the same
        /// keys, went on 2026-10-09; the Space keeps its own (`space.layout`,
        /// `space.sort`).
        static let notebooksHomeLayout = DeviceKey<String?>("notebooks.home.layout.v1", reason: "device-local: Grid or List on this device's Home")
        static let notebooksHomeSort = DeviceKey<String?>("notebooks.home.sort.v1", reason: "device-local: the sort on this device's Home")
        static let notebooksHomeSortReversed = DeviceKey<Bool>("notebooks.home.sortReversed.v1", default: false, reason: "device-local: the sort's direction on this device's Home")
        /// When this Mac last worked in each notebook: which notebook a new
        /// window here opens in is this Mac's arrangement, like its windows,
        /// and opening a notebook must write nothing that travels.
        static let notebookLastWorked = DeviceKey<[String: Any]?>("studio.notebookLastWorked.v1", coding: .dictionary, reason: "device-local: the notebook each new window on this Mac opens in")
        static let createStripHidden = DeviceKey<Bool>("space.createStripHidden", default: false, reason: "device-local: whether this Mac's Space puts away its Create in Space row")

        static let all: [AnyPreferenceKey] = [
            recents.erased,
            layout.erased,
            sort.erased,
            groupByCollection.erased,
            sidebarHidden.erased,
            pagesExpanded.erased,
            boardLens.erased,
            sidebarRecentsFolded.erased,
            notebooksHomeLayout.erased,
            notebooksHomeSort.erased,
            notebooksHomeSortReversed.erased,
            notebookLastWorked.erased,
            createStripHidden.erased,
        ]
    }
}
