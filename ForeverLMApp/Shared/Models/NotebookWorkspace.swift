import Foundation

/// The notebook a Studio window holds, and how the window has it arranged.
///
/// A notebook belongs to the window it is open in (docs/notebooks-design.md,
/// "A notebook belongs to its window"): two windows can hold two notebooks,
/// and a window comes back after a relaunch holding the one it had.
/// `StudioWindowState.notebook` carries one of these; the scene `Snapshot`
/// keeps it without its moments (`persisted`), and no template key ever
/// does, so a brand-new window never opens into somebody's notebook.
///
/// While a window holds one, the notebook workspace (`NotebookWorkspaceView`)
/// draws the notebook's Sources column and its Studio column around the
/// window's own tabbed panes — a chat, the Space, Pages, the Library, a
/// video — which a learner splits, drags and closes as anywhere else
/// (docs/ui-design.md rule 8; product owner, 2026-11-07: "the notebook should
/// actually borrow the way we now have the tab set up in the main view").
/// The chat and one document slot it drew until then are gone.
struct NotebookWorkspace: Codable, Equatable {
    /// The notebook this window works in.
    var notebookID: String
    /// Whether the leading Sources column is folded to its strip. Folded, it
    /// shows no list, so however it folds — its own button, the Notebook
    /// menu, a narrow window — the widened results list goes with it.
    var sourcesCollapsed: Bool {
        didSet { if sourcesCollapsed { sourcesExpanded = false } }
    }
    /// Whether the Sources column shows a web or PubMed search's whole list,
    /// widened for it while the Studio narrows (Gemini's Source Discovery).
    /// A moment: `persisted` leaves it out.
    var sourcesExpanded: Bool
    /// Whether the trailing Studio column is folded to its strip.
    var studioCollapsed: Bool

    /// The defaults are a notebook as it first opens: both columns open.
    init(
        notebookID: String,
        sourcesCollapsed: Bool = false,
        sourcesExpanded: Bool = false,
        studioCollapsed: Bool = false
    ) {
        self.notebookID = notebookID
        self.sourcesCollapsed = sourcesCollapsed
        self.sourcesExpanded = sourcesExpanded
        self.studioCollapsed = studioCollapsed
    }

    /// The workspace as the scene snapshot keeps it: the arrangement without
    /// its moments.
    var persisted: NotebookWorkspace {
        var kept = self
        kept.sourcesExpanded = false
        return kept
    }

    /// The workspace a window holds once `notebookID` opens in it. Opening the
    /// notebook the window already holds keeps how it is arranged; any other
    /// notebook starts fresh.
    static func opening(_ notebookID: String, over current: NotebookWorkspace?) -> NotebookWorkspace {
        if let current, current.notebookID == notebookID { return current }
        return NotebookWorkspace(notebookID: notebookID)
    }

    // MARK: Codable

    /// `studioCollapsed` keeps the key build 175 and 176 wrote for their
    /// trailing column, which was the Studio whenever a notebook first
    /// opened, so a window folded there comes back folded. The keys the chat
    /// and slot layout wrote (`document`, `showsChat`, `tabbed`, …) are no
    /// longer read.
    private enum CodingKeys: String, CodingKey {
        case notebookID, sourcesCollapsed
        case studioCollapsed = "trailingCollapsed"
        /// The key a window's snapshot carried before a notebook stopped being
        /// called a project; read, never written.
        case retiredProjectID = "projectID"
    }

    /// Reads a workspace another build wrote. A key that build did not write
    /// takes the value a freshly opened workspace has, so a newer build's
    /// snapshot still reopens the notebook. Only the notebook itself is
    /// required: a failure here fails the window's whole scene snapshot,
    /// layout and all, so nothing this build writes may fail it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let notebookID = try container.decodeIfPresent(String.self, forKey: .notebookID)
            ?? container.decode(String.self, forKey: .retiredProjectID)
        let fresh = NotebookWorkspace(notebookID: notebookID)
        self.notebookID = notebookID
        sourcesCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sourcesCollapsed)
            ?? fresh.sourcesCollapsed
        sourcesExpanded = false
        studioCollapsed = try container.decodeIfPresent(Bool.self, forKey: .studioCollapsed)
            ?? fresh.studioCollapsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notebookID, forKey: .notebookID)
        try container.encode(sourcesCollapsed, forKey: .sourcesCollapsed)
        try container.encode(studioCollapsed, forKey: .studioCollapsed)
    }

    /// The notebook a chat filed under `goalID` belongs in, for the rule that
    /// a chat opens in its own notebook's workspace: the Notebook it is filed
    /// in, or the Notebook a Goal it is filed under draws on — the same rule
    /// as the rail's grouping (`reviewSessionGroups`). Nil for a library
    /// chat: filed nowhere, on a standalone Goal, or in a notebook that is
    /// not active (archived, deleted, another library's).
    static func home(
        ofChatFiledUnder goalID: String?,
        notebookIDs: Set<String>,
        parentNotebookByGoalID: [String: String]
    ) -> String? {
        guard let goalID, !goalID.isEmpty else { return nil }
        if notebookIDs.contains(goalID) { return goalID }
        if let parent = parentNotebookByGoalID[goalID], notebookIDs.contains(parent) { return parent }
        return nil
    }
}

/// A picture the chat popped out beside itself: the bytes the figure shows and
/// the caption it carries. Plain values; the Mac draws it in a picture window
/// (`ChatPictureWindow`). Two are the same picture when they are the same
/// opening, never by comparing bytes.
struct DockedChatPicture: Equatable, Sendable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let title: String?

    static func == (lhs: DockedChatPicture, rhs: DockedChatPicture) -> Bool { lhs.id == rhs.id }
}
