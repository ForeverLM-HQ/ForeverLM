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
/// draws the window body in Gemini Notebook's three parts: the notebook's
/// Sources column, its chat with one document slot beside it, and its Studio
/// column (docs/notebooks-design.md, "The notebook workspace"). The panes
/// underneath are left as they were and come back when the notebook closes.
struct NotebookWorkspace: Codable, Equatable {
    /// The notebook this window works in.
    var notebookID: String
    /// What the center's document slot shows beside Chat, if anything. A
    /// moment, not an arrangement: `persisted` leaves it out, as
    /// `StudioWindowContent` is left out of the scene snapshot.
    var document: NotebookDocument?
    /// The documents open as tabs in the slot, in tab order: what the slot
    /// held stays one of its tabs when another document takes it, as a pane's
    /// tabs do outside a notebook (docs/ui-design.md rule 8). `document` is the
    /// one showing. Kept only while two or more are open (`kept`), so a slot
    /// with one document is the same workspace however it got there. Read
    /// through `slotTabStrip`, which also counts a `document` that was set
    /// without going through a tab. A moment, like `document`.
    var slotTabs: [NotebookDocument] = []
    /// What stands in the chat's place while Chat is hidden: the Reader a
    /// link in the document opened beside it (docs/notebooks-design.md,
    /// "Following a link never closes what you read it in"). Only ever set
    /// while `showsChat` is false; Chat coming back moves it into the slot.
    /// A moment, like `document`.
    var leadingDocument: NotebookDocument?
    /// What the document slot held before the Reader took it, for the
    /// Reader's "Back to …" in its band. Set only while the slot shows the
    /// Reader. A moment, like `document`.
    var returnDocument: NotebookDocument?
    /// Whether the center shows the notebook's chat. Its × hides it, and the
    /// center then shows the notebook's overview.
    var showsChat: Bool
    /// Whether the leading Sources column is folded to its strip. Folded, it
    /// shows no list, so however it folds — its own button, the Notebook
    /// menu, a narrow window — the widened results list goes with it.
    var sourcesCollapsed: Bool {
        didSet { if sourcesCollapsed { sourcesExpanded = false } }
    }
    /// Whether the Sources column shows a web or PubMed search's whole list,
    /// widened for it while the Studio narrows (Gemini's Source Discovery).
    /// A moment, like `document`.
    var sourcesExpanded: Bool
    /// Whether the trailing Studio column is folded to its strip.
    var studioCollapsed: Bool
    /// Which side of the chat the document slot stands on while both show:
    /// true puts the document (the Reader above all) to the chat's left, the
    /// default since 2026-10-04, and the divider's swap button flips it. An
    /// arrangement, so `persisted` keeps it.
    var documentLeads: Bool
    /// Whether the center is the window's own tabbed panes instead of the
    /// chat and one document slot: the notebook's Sources and Studio columns
    /// stand around the panes the window already had (a chat, the Space, a
    /// video, notes), which a learner splits, drags and closes as anywhere
    /// else (docs/ui-design.md rule 8). Set when a notebook opens in a window
    /// that was showing two panes or more, so opening a notebook from the
    /// Space no longer takes the window from the chat beside it. While it
    /// is set the slot and the notebook routing are not used
    /// (`StudioWindowState.holdsNotebookSlot`). An arrangement, so `persisted`
    /// keeps it.
    var tabbed: Bool

    /// The defaults are a notebook as it first opens: its chat showing, both
    /// columns open, nothing in the document slot.
    init(
        notebookID: String,
        document: NotebookDocument? = nil,
        slotTabs: [NotebookDocument] = [],
        leadingDocument: NotebookDocument? = nil,
        returnDocument: NotebookDocument? = nil,
        showsChat: Bool = true,
        sourcesCollapsed: Bool = false,
        sourcesExpanded: Bool = false,
        studioCollapsed: Bool = false,
        documentLeads: Bool = true,
        tabbed: Bool = false
    ) {
        self.notebookID = notebookID
        self.document = document
        self.slotTabs = slotTabs
        self.leadingDocument = leadingDocument
        self.returnDocument = returnDocument
        self.showsChat = showsChat
        self.sourcesCollapsed = sourcesCollapsed
        self.sourcesExpanded = sourcesExpanded
        self.studioCollapsed = studioCollapsed
        self.documentLeads = documentLeads
        self.tabbed = tabbed
    }

    /// Whether the document is drawn to the chat's left: only while both
    /// show, since a lone pane has no side to stand on.
    var documentPrecedesChat: Bool {
        documentLeads && showsChat && document != nil
    }

    /// The workspace as the scene snapshot keeps it: the arrangement without
    /// its moments, so a relaunch reopens the notebook and not the paper
    /// that happened to be beside its chat.
    var persisted: NotebookWorkspace {
        var kept = self
        kept.document = nil
        kept.slotTabs = []
        kept.leadingDocument = nil
        kept.returnDocument = nil
        kept.sourcesExpanded = false
        return kept
    }

    /// The workspace a window holds once `notebookID` opens in it. Opening the
    /// notebook the window already holds keeps how it is arranged, document
    /// included; any other notebook starts fresh.
    static func opening(_ notebookID: String, over current: NotebookWorkspace?) -> NotebookWorkspace {
        if let current, current.notebookID == notebookID { return current }
        return NotebookWorkspace(notebookID: notebookID)
    }

    // MARK: Codable

    /// `studioCollapsed` keeps the key build 175 and 176 wrote for their
    /// trailing column, which was the Studio whenever a notebook first
    /// opened, so a window folded there comes back folded. Their `trailing`
    /// face (Studio, Library or About) is no longer read: the right column is
    /// the Studio alone, and About is the notebook's settings sheet.
    private enum CodingKeys: String, CodingKey {
        case notebookID, document, leadingDocument, returnDocument
        case showsChat, sourcesCollapsed, documentLeads, tabbed
        case studioCollapsed = "trailingCollapsed"
        /// The key a window's snapshot carried before a notebook stopped being
        /// called a project; read, never written.
        case retiredProjectID = "projectID"
    }

    /// Reads a workspace another build wrote. A key that build did not write
    /// takes the value a freshly opened workspace has, and a document this
    /// build does not know is left out, so a newer build's snapshot still
    /// reopens the notebook. Only the notebook itself is required: a failure
    /// here fails the window's whole scene snapshot, layout and all, so
    /// nothing this build writes may fail it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let notebookID = try container.decodeIfPresent(String.self, forKey: .notebookID)
            ?? container.decode(String.self, forKey: .retiredProjectID)
        let fresh = NotebookWorkspace(notebookID: notebookID)
        self.notebookID = notebookID
        document = try? container.decodeIfPresent(NotebookDocument.self, forKey: .document)
        leadingDocument = try? container.decodeIfPresent(NotebookDocument.self, forKey: .leadingDocument)
        returnDocument = try? container.decodeIfPresent(NotebookDocument.self, forKey: .returnDocument)
        showsChat = try container.decodeIfPresent(Bool.self, forKey: .showsChat) ?? fresh.showsChat
        sourcesCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sourcesCollapsed)
            ?? fresh.sourcesCollapsed
        sourcesExpanded = false
        studioCollapsed = try container.decodeIfPresent(Bool.self, forKey: .studioCollapsed)
            ?? fresh.studioCollapsed
        documentLeads = try container.decodeIfPresent(Bool.self, forKey: .documentLeads) ?? fresh.documentLeads
        tabbed = try container.decodeIfPresent(Bool.self, forKey: .tabbed) ?? fresh.tabbed
        // A chat on screen has the chat's place to itself.
        if showsChat { leadingDocument = nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notebookID, forKey: .notebookID)
        try container.encodeIfPresent(document, forKey: .document)
        try container.encodeIfPresent(leadingDocument, forKey: .leadingDocument)
        try container.encodeIfPresent(returnDocument, forKey: .returnDocument)
        try container.encode(showsChat, forKey: .showsChat)
        try container.encode(sourcesCollapsed, forKey: .sourcesCollapsed)
        try container.encode(studioCollapsed, forKey: .studioCollapsed)
        try container.encode(documentLeads, forKey: .documentLeads)
        try container.encode(tabbed, forKey: .tabbed)
    }
}

/// What the notebook's document slot can show beside its chat: one at a time,
/// each replacing the last. An output of the notebook opens in the one its
/// kind names: a Doc, Site or animation in its canvas, a course in its page,
/// and a walkthrough, an explainer (spoken or filmed) or an audio
/// overview's script in the Reader, since each of those is a source.
enum NotebookDocument: String, Codable, CaseIterable {
    case reader
    case docs
    case sites
    case animations
    /// Card practice in the slot, which the shell plan drew. No center tab
    /// routes here: the notebook's cards are reviewed in the Memory pane
    /// (`memory`, below) and the window-filling memory focus its Start
    /// Review opens (`StudioViewModel.requestCardReview(scope:)`).
    case flashcards
    /// One course's page. A lecture opened from it takes the slot in the
    /// Reader, whose "Back to <course>" brings the page back
    /// (`returnDocument`): the lectures' back stack.
    case coursePage
    /// The web: Discover, and cited pages before they join the library.
    case browser
    /// A second conversation beside the notebook's chat.
    case secondChat
    /// The Memory pane: every notebook's cards, or this notebook's when its
    /// Studio Cards tile opened it (docs/memory-design.md, "The card review").
    case memory
    /// One picture from the chat, big, beside the conversation it came from:
    /// the figure's Open beside. No center tab routes here; the window holds
    /// the bytes (`StudioWindowState.dockedPicture`), and the pane's × or the
    /// next picture sent beside takes the slot back.
    case picture
}

/// A picture the chat popped out beside itself: the bytes the figure shows and
/// the caption it carries. Plain values, so the shared window state can hold
/// it; the Mac draws it (`ChatPicturePane`). Two are the same picture when
/// they are the same opening, never by comparing bytes.
struct DockedChatPicture: Equatable, Sendable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let title: String?

    static func == (lhs: DockedChatPicture, rhs: DockedChatPicture) -> Bool { lhs.id == rhs.id }
}

/// Where a request for a center tab goes in a window that holds a notebook.
enum NotebookRoute: Equatable {
    /// Show the notebook's chat.
    case chat
    /// Show this in the document slot beside the chat.
    case document(NotebookDocument)
    /// The surface has no place in a notebook: the window leaves the notebook,
    /// the panes underneath come back as they were, and the tab opens there.
    case leave
}

extension NotebookDocument {
    /// The center tab a request names to reach this document, and the one a
    /// window holding it reports as on screen. Nil for card practice, which
    /// no center tab routes to.
    var centerTab: StudioCenterTab? {
        switch self {
        case .reader: return .reader
        case .docs: return .notepad
        case .sites: return .sites
        case .animations: return .animations
        case .flashcards: return nil
        case .coursePage: return .courses
        case .browser: return .browser
        case .secondChat: return .secondaryChat
        case .memory: return .memory
        case .picture: return nil
        }
    }

    /// A second conversation is a chat and needs a chat's width; everything
    /// else in the slot is something to read.
    var isChat: Bool { self == .secondChat }
}

extension NotebookWorkspace {
    /// The one routing table for a notebook window. The center-tab entry
    /// points (activate, reveal, open beside, second chat, deactivate,
    /// dismiss) ask it first while the window holds a notebook, so a click
    /// anywhere lands in the notebook's chat or its document slot, or leaves
    /// the notebook for the panes underneath. `coursePageID` is the window's
    /// open course page: Courses with a page is a document, the course list
    /// is not. Videos leaves for the same reason: it is the library's list of
    /// explainer films, and one film — like a spoken explainer — is a source,
    /// which opens in the Reader, the document slot.
    static func route(_ tab: StudioCenterTab, coursePageID: String?) -> NotebookRoute {
        switch tab {
        case .chat: return .chat
        case .secondaryChat: return .document(.secondChat)
        case .reader: return .document(.reader)
        case .notepad: return .document(.docs)
        case .sites: return .document(.sites)
        case .animations: return .document(.animations)
        case .browser: return .document(.browser)
        case .courses: return coursePageID == nil ? .leave : .document(.coursePage)
        // Memory spans every notebook and is narrowed to one from inside
        // it, so it opens in the slot rather than leaving the notebook.
        case .memory: return .document(.memory)
        // The Space and the full-window Library are the library's places:
        // they leave the notebook, which its rail row and its row in the
        // Space bring back as it was (`notebookLeft`). Inside
        // the notebook the library is its Sources column's search. Plugins
        // are the app's, as the Library is.
        case .library, .knowledgeMap, .atlas, .plugins: return .leave
        case .activity, .tasks, .goals, .ideas, .videos, .artifacts: return .leave
        }
    }

    /// The center tabs this workspace has on screen: Chat while it shows (or
    /// the document standing in its place), and the slot's document. What a
    /// window holding a notebook answers when asked which tabs are visible
    /// (`StudioViewModel.activeCenterTabs`), so "is Chat showing" keeps its
    /// meaning inside a notebook.
    var visibleTabs: Set<StudioCenterTab> {
        var tabs: Set<StudioCenterTab> = []
        if showsChat { tabs.insert(.chat) }
        if let tab = leadingDocument?.centerTab { tabs.insert(tab) }
        if let tab = document?.centerTab { tabs.insert(tab) }
        return tabs
    }

    /// The documents on screen, left to right: the one in the chat's place,
    /// then the slot's.
    var visibleDocuments: [NotebookDocument] {
        [leadingDocument, document].compactMap { $0 }
    }

    /// Whether a second conversation is on screen, in the slot or in the
    /// chat's place.
    var showsSecondChat: Bool {
        visibleDocuments.contains(.secondChat)
    }

    /// How many panes the center draws side by side: the chat or the
    /// document in its place, and the slot's document. Zero means the
    /// notebook's overview.
    var centerPaneCount: Int {
        (showsChat || leadingDocument != nil ? 1 : 0) + (document == nil ? 0 : 1)
    }

    /// The workspace once `route` is followed: Chat comes on screen, or the
    /// document takes the slot, replacing what it held. A document already
    /// on screen is left where it is. Nil for `.leave`: the window leaves the
    /// notebook.
    func following(_ route: NotebookRoute) -> NotebookWorkspace? {
        var next = self
        switch route {
        case .chat:
            next.showsChat = true
            // Chat takes its place back; what stood there moves into the
            // slot, the latest thing the learner opened.
            if let lead = next.leadingDocument {
                next.leadingDocument = nil
                next.placeInSlot(lead)
            }
        case .document(let document):
            guard document != next.leadingDocument else { break }
            next.placeInSlot(document)
        case .leave:
            return nil
        }
        return next
    }

    /// The slot shows `document`. The Reader taking it from another document
    /// remembers that one for its "Back to …"; anything else forgets it, and
    /// the slot already showing `document` changes nothing.
    private mutating func placeInSlot(_ document: NotebookDocument) {
        guard document != self.document else { return }
        var tabs = slotTabStrip
        if document == .reader, let previous = self.document {
            returnDocument = previous
        } else {
            returnDocument = nil
        }
        if document.centerTab != nil, !tabs.contains(document) { tabs.append(document) }
        slotTabs = Self.kept(tabs)
        self.document = document
    }

    /// The tabs worth storing: none while at most one document is open.
    private static func kept(_ tabs: [NotebookDocument]) -> [NotebookDocument] {
        tabs.count > 1 ? tabs : []
    }

    /// The slot's tabs left to right: the documents opened in it, then the
    /// one showing if it was set without a tab. Only documents a center tab
    /// reaches are tabs; a chat's picture, which has none, replaces the slot
    /// for as long as it shows and leaves the tabs as they were.
    var slotTabStrip: [NotebookDocument] {
        var tabs = slotTabs.filter { $0.centerTab != nil }
        if let document, document.centerTab != nil, !tabs.contains(document) { tabs.append(document) }
        return tabs
    }

    /// Whether the slot draws a tab strip: two documents or more are open in
    /// it and one of them is showing.
    var slotShowsTabStrip: Bool {
        guard let document, document.centerTab != nil else { return false }
        return slotTabStrip.count > 1
    }

    /// Closes `tab` in the slot, an inactive tab included. The slot then
    /// shows the neighbouring tab, the one to its right, else its left, and
    /// is empty when it was the last.
    private mutating func closeSlotTab(_ closed: NotebookDocument) {
        let tabs = slotTabStrip
        guard let index = tabs.firstIndex(of: closed) else { return }
        let remaining = tabs.filter { $0 != closed }
        slotTabs = Self.kept(remaining)
        if document == closed {
            document = remaining.indices.contains(index) ? remaining[index] : remaining.last
            returnDocument = nil
        }
    }

    /// The workspace once `tab` is dragged to a side of the slot (or sent
    /// there with Split Left / Split Right): the slot's documents stand side
    /// by side, `tab` on the trailing side for `toTrailing` and the leading
    /// side otherwise, the document that was showing beside it. The pair is
    /// the one place a notebook holds two documents at once, so Chat steps
    /// aside (its × hides it the same way) and the document on the leading
    /// side takes the chat's place (`leadingDocument`); Chat coming back
    /// moves both into the slot as tabs again (`following`). Nil unless the
    /// slot holds `tab` and another document.
    func splittingSlot(moving tab: StudioCenterTab, toTrailing: Bool) -> NotebookWorkspace? {
        let strip = slotTabStrip
        guard strip.count > 1, let moved = strip.first(where: { $0.centerTab == tab }) else { return nil }
        let others = strip.filter { $0 != moved }
        let partner = document.flatMap { others.contains($0) ? $0 : nil } ?? others[0]
        var next = self
        next.showsChat = false
        let leading = toTrailing ? partner : moved
        next.leadingDocument = leading
        next.slotTabs = Self.kept(strip.filter { $0 != leading })
        next.document = toTrailing ? moved : partner
        next.returnDocument = nil
        return next
    }

    /// The workspace once the slot's × is pressed with a tab strip showing:
    /// the whole slot closes, every tab with it.
    func closingSlot() -> NotebookWorkspace {
        var next = self
        next.document = nil
        next.slotTabs = []
        next.returnDocument = nil
        return next
    }

    /// The workspace once `tab`'s surface is closed — its × or a request to
    /// hide it: the document in the chat's place or in the slot goes, or
    /// Chat hides. A tab the notebook does not have on screen changes
    /// nothing; the panes underneath are not this workspace's to rearrange.
    func closing(_ tab: StudioCenterTab) -> NotebookWorkspace {
        var next = self
        if tab == .chat {
            next.showsChat = false
        } else if let lead = leadingDocument, lead.centerTab == tab {
            next.leadingDocument = nil
        } else if let closed = slotTabStrip.first(where: { $0.centerTab == tab }) {
            next.closeSlotTab(closed)
        }
        return next
    }

    /// The workspace once the slot's picture is closed: the slot empties. A
    /// slot showing anything else is left alone.
    func closingPicture() -> NotebookWorkspace {
        guard document == .picture else { return self }
        var next = self
        // The tabs the picture covered come back, the latest on top.
        next.document = slotTabs.last
        next.returnDocument = nil
        return next
    }

    /// The Reader's "Back to …": the slot shows again what the Reader took
    /// it from. Unchanged when there is nothing to go back to.
    func returning() -> NotebookWorkspace {
        guard document == .reader, let previous = returnDocument else { return self }
        var next = self
        // Back is a back stack, not a tab: the Reader goes as the slot returns.
        next.slotTabs = Self.kept(slotTabStrip.filter { $0 != .reader })
        next.document = previous
        next.returnDocument = nil
        return next
    }

    /// A request to show `tab` beside `companion`, followed in the notebook.
    /// Nil when `tab` has no place here (the window leaves the notebook and
    /// the panes underneath take the request). The companion is the surface
    /// the request came from, and following a link never closes what it was
    /// read in:
    /// - beside the chat, the tab takes the slot and the chat shows;
    /// - a chat asked beside a document shows beside that document;
    /// - a document asked from the document on screen, with Chat hidden,
    ///   opens in the chat's place beside it; with Chat showing it takes the
    ///   slot, and the Reader then offers "Back to" what it replaced.
    /// A companion with no place here is not on screen in a notebook window
    /// and is passed over.
    func revealing(
        _ tab: StudioCenterTab,
        beside companion: StudioCenterTab,
        coursePageID: String?
    ) -> NotebookWorkspace? {
        let tabRoute = Self.route(tab, coursePageID: coursePageID)
        guard tabRoute != .leave else { return nil }
        switch Self.route(companion, coursePageID: coursePageID) {
        case .chat:
            return following(.chat)?.following(tabRoute)
        case .document(let source) where tabRoute == .chat:
            // The chat comes back beside the document it was asked from.
            if source == leadingDocument { return following(.chat) }
            return following(.document(source))?.following(.chat)
        case .document(let source):
            guard case .document(let target) = tabRoute, target != source,
                  !showsChat, source == document || source == leadingDocument else {
                return following(tabRoute)
            }
            var next = self
            if source == document {
                // In the chat's place, beside the document it came from.
                next.leadingDocument = target
            } else {
                // From the document in the chat's place: the slot takes it.
                next.placeInSlot(target)
            }
            return next
        case .leave:
            return following(tabRoute)
        }
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
