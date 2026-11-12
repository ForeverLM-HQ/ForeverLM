import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

struct InternalReviewPanel: View {
    /// The session store owns conversation lifetimes independently of this
    /// transient view. Selecting another chat swaps the projected manager while
    /// a running manager continues its turn in the background.
    let sessionStore: StudioAssistantSessionStore
    let onDismiss: () -> Void
    var onPopOut: (() -> Void)?
    /// Height of the scrollable transcript in the compact bottom-sheet host. Ignored when
    /// `fillsAvailableSpace` is set — the transcript then flexes to fill the panel.
    var transcriptHeight: CGFloat = 320
    /// When hosted in a fixed panel (docked Chat column, pop-out window), expand the
    /// transcript to fill the available height — title at the top, composer at the
    /// bottom — so the entire visible panel accepts source drops.
    var fillsAvailableSpace: Bool = false
    /// Docked under the center tab strip, the chat title renders as a compact
    /// header row with the reader toolbar's height and lift, putting the Chat
    /// and Reader header lines at the same height across panes. The pop-out
    /// window keeps the regular in-content header.
    var usesDockedHeaderChrome: Bool = false
    /// How far in from this panel's trailing edge the chat header's own
    /// controls must stop, so the header's ⋯ keeps the shared control gap
    /// from the pin and pane close drawn over the pane's top-right corner.
    /// Only a docked host has that chrome; everywhere else this is zero.
    var headerTrailingChromeClearance: CGFloat = 0
    /// How far in from this panel's leading edge the chat title must start, to
    /// clear the window's ‹ › and sidebar toggle when this is the leftmost
    /// pane. Zero everywhere else.
    var headerLeadingChromeClearance: CGFloat = 0
    /// A chat that owns its whole pane can use a wider reading column. Split
    /// layouts keep the compact cap so Chat and Reader remain comfortable side
    /// by side; the panel width still constrains either mode on smaller windows.
    var expandsChatContent: Bool = false
    /// Only the primary Chat consumes app-wide navigation requests. A dragged
    /// comparison pane receives requests through its own session store so two
    /// visible panels never race to resume the same chat.
    var acceptsGlobalNavigationRequests = true
    /// The Studio window this panel belongs to. Global requests are stamped
    /// with the window they were made in, and a panel that knows its window
    /// acts only on those; nil keeps the pre-multi-window behaviour.
    var ownerWindowID: UUID? = nil
    /// How this pane opens a new chat beside itself on handed-in context — an
    /// exchange lifted out of a memory review. nil where there is no
    /// neighbour to hand to (a comparison pane, the pop-out window); the
    /// app-wide request then carries it to the primary Chat instead.
    var onOpenNewChatBeside: ((ReaderSelectionExplanationRequest) -> Void)? = nil
    /// How the panel is drawn. The default is the docked pane's; the page's
    /// side chat draws the same conversation as a compact card
    /// (docs/pages-side-chat-design.md).
    var presentation: ChatPanelPresentation = .pane

    var body: some View {
        InternalReviewPanelContent(
            sessionStore: sessionStore,
            manager: sessionStore.activeManager,
            onDismiss: onDismiss,
            onPopOut: onPopOut,
            transcriptHeight: transcriptHeight,
            fillsAvailableSpace: fillsAvailableSpace,
            usesDockedHeaderChrome: usesDockedHeaderChrome,
            headerTrailingChromeClearance: headerTrailingChromeClearance,
            headerLeadingChromeClearance: headerLeadingChromeClearance,
            expandsChatContent: expandsChatContent,
            acceptsGlobalNavigationRequests: acceptsGlobalNavigationRequests,
            ownerWindowID: ownerWindowID,
            onOpenNewChatBeside: onOpenNewChatBeside,
            presentation: presentation
        )
        .id(ObjectIdentifier(sessionStore.activeManager))
    }
}

struct InternalReviewPanelContent: View {
    let sessionStore: StudioAssistantSessionStore
    /// Stable for this content instance. Async work that began here keeps
    /// targeting the same conversation even after the store selects another.
    let manager: ReviewSessionManager
    let onDismiss: () -> Void
    var onPopOut: (() -> Void)?
    var transcriptHeight: CGFloat
    var fillsAvailableSpace: Bool
    var usesDockedHeaderChrome: Bool
    var headerTrailingChromeClearance: CGFloat
    var headerLeadingChromeClearance: CGFloat
    var expandsChatContent: Bool
    var acceptsGlobalNavigationRequests: Bool
    var ownerWindowID: UUID?
    var onOpenNewChatBeside: ((ReaderSelectionExplanationRequest) -> Void)?
    var presentation: ChatPanelPresentation

    /// The page side chat's card, when this panel is drawn as one.
    var pageSideChat: PageSideChatPresentation? {
        guard case .pageSideChat(let card) = presentation else { return nil }
        return card
    }

    @Environment(StudioViewModel.self) var vm
    /// The window this pane sits in, for which sources its Readers have on
    /// screen. Optional: a chat hosted outside a Studio window has no Reader
    /// beside it, and a played step then keeps its lens.
    @Environment(StudioWindowState.self) var windowState: StudioWindowState?
    @Environment(\.openWindow) var openWindow
    @Environment(\.studioTitlebarBandHeight) var titlebarBandHeight
    @PreferenceStorage(Prefs.Studio.zoomStep, default: UIZoom.defaultStep) var uiZoomStep
    let dragVisibility = StudioDragVisibility.shared
    /// The daily time budget, which is also the day's goal; the idle screen's
    /// Memory check row says how long the review is planned to take, and the
    /// Memory row's badge counts the same number down.
    @PreferenceStorage(Prefs.Memory.budgetMinutes, default: MemoryReviewBudget.defaultMinutes)
    var memoryBudgetMinutes
    /// This panel's identity with the day's goal clock, minted once per view.
    /// The review moves between hosts when the window gives itself over to it
    /// and back, which builds a new panel around the same session manager
    /// before the old one goes away; a token per panel keeps the departing one
    /// from cancelling the arriving one's registration.
    @State var memoryGoalPanelToken = UUID()
    /// Unread sources nearest to recent reading, best first, for the empty
    /// chat's "Read next" row. Found off-main each time the welcome appears.
    @State var readNextSuggestions: [ReadNextSuggestion] = []
    /// Three questions drawn from the canvas this chat was opened beside, for
    /// the empty state (`StudioViewModel.openChatBesideKnowledgeMap`); gone
    /// once the chat has anything in it.
    @State var canvasSuggestedQuestions: [String] = []
    @StateObject var dictation = ReviewDictationService()
    @StateObject var speech = ReviewSpeechService()
    /// The composer's text and popup state, observed only by the composer views.
    /// The pane reads it from actions, never in its body, so typing does not
    /// re-render the transcript. See `ReviewComposerDraft`.
    @State var composer = ReviewComposerDraft()
    /// The quote as a Page's highlight last set it (`mirrorPageSelection`).
    @State var mirroredPageQuote: String?
    /// Skip was pressed and its message has not gone out yet: the footer's
    /// icon hides, so a second click cannot skip the next question too.
    @State var isSkippingQuizQuestion = false
    @State var manualDictationTranscriptionTask: Task<String?, Never>?
    @State var manualDictationResultDestination: ManualDictationResultDestination?
    /// Which source each `[n]` in this transcript names, and whose card the
    /// conversation has already shown. A row cannot work its own out — the
    /// answer depends on every reply above it — so the transcript stack rebuilds
    /// it here whenever the set of replies changes. See `ChatCitationLedger`.
    @State var citationContexts: [UUID: ChatCitationLedger.MessageContext] = [:]
    @State var isDropTargeted = false
    @State var dropTargetResetTask: Task<Void, Never>?

    @State var isSessionBrowserPresented = false
    @State var linkedResearchNotebookID: String?
    /// The Notebook whose Feynman Technique the chat asked for
    /// (`start_feynman_technique`), opened once the answer that asked ends.
    @State private var pendingTeachBackNotebookID: String?
    /// Set when a notebook opening in this window started this chat
    /// (`StudioViewModel.pendingNotebookChatRequestID`), or an idle chat
    /// joined its window's notebook. Until the learner acts here, the chat
    /// reads its notebook's ticked sources live rather than the shared
    /// context, because opening a notebook writes nothing; the first thing
    /// the learner does here adopts them (`adoptLiveNotebookSelection`).
    /// Only this window ends it: its own setting of the context, here or
    /// from its sidebar (`contextSourcesWrite`). Another window's chat
    /// seeding the shared context does not.
    @State var readsNotebookTicksLive = false
    /// Bumped when the notebook's kept questions change, so its guide reads
    /// them again (`NotebookSuggestedQuestionRows` live in the defaults).
    @State var notebookQuestionsRevision = 0
    @State var isContextSourcesPopoverPresented = false
    @State var isContextSourcesChipHovering = false
    /// The ⋯'s Context and Cost…: the composer draws its context ring,
    /// although the window is not yet filling up, and the ring opens its
    /// breakdown; the ring sets this back once the breakdown closes.
    @State var isContextBreakdownRequested = false
    /// The chat's title is a field: Codex's rename, from a click on the title
    /// or the header's Rename….
    @State var isRenamingChatTitle = false
    @State var chatTitleDraft = ""
    @FocusState var chatTitleFieldFocused: Bool
    /// New Notebook from This Chat, asked from the notebook picker or ⋯.
    @State var notebookFromChatRequest: NotebookFromChatRequest?
    /// The composer sends the next message as a side question: an aside about
    /// a reply that the tutor answers without moving the conversation on, and
    /// without grading while a question is open. Set from the footer icon on
    /// any reply, shown as a token at the head of the field, and off again
    /// once the learner answers or takes it off.
    @State var isSideQuestionMode = false
    /// Think first's chat moment (docs/fences-and-think-first-design.md): a
    /// question the learner sent in a notebook's chat, held while the field
    /// asks "Your guess first?". Return sends it with the guess, the token's ×
    /// or Escape sends it at once.
    @State var pendingGuessedQuestion: ComposedChatSend?
    /// The composer holds Generate's "I want to make a course about " and
    /// the message it becomes goes with the course-planning instructions
    /// (`CoursePlanningChat`). Cleared with the composer, so a chat the
    /// learner moved on to never inherits them.
    @State var coursePlanningArmed = false
    /// Set when a chat opens on the day-planning line (`requestPlanDayChat`):
    /// the rules ride with the learner's send, hidden, the way a course's do.
    @State var dayPlanningArmed = false
    /// The reply the armed side question is about. Nil with the token off, or
    /// when ⌥Return sends one without arming: then it is the newest reply.
    @State var sideQuestionTarget: ReviewChatReplyReference?
    /// The side chat open over words selected in one of this transcript's
    /// replies, while it is open. One at a time: a second selection's side
    /// chat takes the first one's place.
    @State var replySideChat: ChatReplySideChatModel?
    /// More details pressed on a reply whose lane already exists: the lane is
    /// asked to open rather than a second one being sent.
    @State var laneExpansionRequest: ReviewChatLaneExpansionRequest?
    @PreferenceStorage(Prefs.Studio.metadataVisibility, default: MetadataVisibilitySettings()) var metadataVisibility
    /// The Doc each answer went into with Save to note, by the answer's block
    /// id (a message id, so a reopened chat starts with none). In memory only.
    @State var answerNoteDocIDs: [UUID: String] = [:]
    /// Answers whose Doc is being made, so a second click makes no second Doc.
    @State var answersBeingSavedToNotes: Set<UUID> = []

    @State var transcriptViewportHeight: CGFloat = 0
    /// When the current turn was sent, for the working indicator's clock. Nil
    /// whenever no turn is in flight. Held by the manager, which outlives
    /// this view, so closing the chat's tab and coming back keeps counting.
    var turnStartedAt: Date? {
        get { manager.workingLineStartedAt }
        nonmutating set { manager.workingLineStartedAt = newValue }
    }
    /// Current pane width, used only to derive a responsive reading measure.
    /// The geometry callback publishes this one lightweight scalar.
    @State var chatPanelWidth: CGFloat = 0
    /// Passage the learner chose to chat about. Attached to the next send, not auto-submitted.
    @State var pendingReaderSelection: ReaderSelectionExplanationRequest?
    /// A walkthrough step's animation the learner asked to see larger.
    @State var expandedWalkthroughAnimation: WalkthroughEnlargedAnimation?
    /// The walkthrough card folded to its title line, to give the chat room.
    @State var isWalkthroughCardFolded = false
    /// The memory review card chosen with Back and Next; nil for the newest,
    /// the one being answered.
    @State var memoryReviewCardIndex: Int?
    /// Whether a memory review is drawn as cards or as its conversation.
    @WindowStorage(Prefs.Memory.reviewLayout, default: MemoryReviewLayout.cards.rawValue) var memoryReviewLayoutRaw
    /// The chat panel's height, which the walkthrough card takes at most a
    /// share of.
    @State var transcriptPanelHeight: CGFloat = 0
    /// The passage a queued message was asked about, kept so the × on its
    /// bubble can hand the passage back along with the words.
    @State var queuedReaderSelections: [UUID: ReaderSelectionExplanationRequest] = [:]
    /// The learner's newest message while Edit has it in the composer: the
    /// send replaces it and the reply after it. What was in the composer
    /// before comes back on Cancel.
    @State var editingMessage: ChatEditMessage.Editing?
    /// Find in this chat (⌘F while focus or the last click is in it).
    @State var chatFind = ChatFind()
    /// The transcript is scrolled up from its newest turn: the jump arrow shows.
    @State var isTranscriptScrolledUp = false
    /// The doc passages this conversation was opened on, once they are saved.
    /// `pendingReaderSelection` is the same thing before the question is sent;
    /// these outlive the send, and the pane, and the app.
    @State var sessionDocLinks: [ArtifactChatLink] = []

    /// The Docs source picker, opened by `/source` when the popup is not the
    /// answer — a bare command, or a search that found nothing.
    @State var slashSourcePickerRequest: SlashSourcePickerRequest?

    struct SlashSourcePickerRequest: Identifiable {
        let id = UUID()
        /// What the learner had typed after `/source`, prefilled into the search.
        let seed: String
    }

    /// Action-side views of the composer state. Read and written from handlers
    /// only: a read from `body` would put the whole pane back on the keystroke
    /// path, which is what `ReviewComposerDraft` exists to prevent.
    var draft: String {
        get { composer.text }
        nonmutating set { composer.text = newValue }
    }

    /// The passage quoted out of this transcript that the next message carries.
    /// It is not part of `draft`: the composer draws it as a quote above the
    /// field, and the send folds it in as a blockquote.
    var quotedPassage: String {
        get { composer.quotedPassage }
        nonmutating set { composer.quotedPassage = newValue }
    }

    var lastInsertedDefaultPrompt: String? {
        get { composer.lastInsertedDefaultPrompt }
        nonmutating set { composer.lastInsertedDefaultPrompt = newValue }
    }

    var slashSelectionIndex: Int {
        get { composer.slashSelectionIndex }
        nonmutating set { composer.slashSelectionIndex = newValue }
    }

    let sessionBrowserPopoverWidth: CGFloat = 440
    let sessionBrowserPopoverHeight: CGFloat = 480
    let contextSourcesPopoverWidth: CGFloat = 380
    let contextSourcesPopoverHeight: CGFloat = 420

    /// The empty chat's greeting keeps a focused column. The composer keeps
    /// the transcript's width (`chatColumnMaxWidth`), so the first message does
    /// not move it sideways, and the suggestions under it take the same width;
    /// the canvas's question cards keep `idleComposerMaxWidth`.
    let idleWelcomeColumnWidth: CGFloat = 420
    let idleComposerMaxWidth: CGFloat = 620

    /// Responsive readable cap for the chat column. A sole Chat pane follows
    /// the window at roughly 72%, bounded so neither a small nor an ultrawide
    /// window produces awkward prose. Split layouts retain the compact width
    /// they were designed around.
    var chatColumnMaxWidth: CGFloat {
        guard expandsChatContent, chatPanelWidth > 0 else { return 700 }
        return min(1_200, max(700, chatPanelWidth * 0.72))
    }

    /// The bubble sits inside 28 points of transcript gutters and leaves a
    /// 48-point trailing breathing space for assistant turns.
    var chatMessageMaxWidth: CGFloat {
        max(620, chatColumnMaxWidth - 76)
    }

    /// Everything attached to this chat — for a Notebook, its whole approved
    /// pool. Availability, not residency: these are the sources the assistant
    /// may reach for, and most of them are only a catalog line in the prompt.
    var reviewSources: [StudioArticle] {
        let paneSources = manager.linkedSourceIDs.compactMap { vm.articlesById[$0] }
        let sources: [StudioArticle]
        if !paneSources.isEmpty {
            sources = paneSources
        } else if pageSideChat != nil {
            // A page's chat stands on what the page handed it, never on
            // whatever the docked chat's idle pool was holding.
            sources = []
        } else if readsNotebookSelectionLive, let notebook = linkedResearchNotebook {
            sources = vm.notebookChatSourceIDs(notebook).compactMap { vm.articlesById[$0] }
        } else {
            sources = vm.contextSourceArticles
        }
        return sources.filter { vm.isSourceIncludedInKnowledge($0) }
    }

    /// Whether this chat still reads its notebook's ticked sources live: it
    /// was started by its notebook opening (or joined it idle), nothing has
    /// been asked, and nothing in this window has set the chat context since
    /// (a passage, a resumed chat, a drop or the library list's Add to Chat
    /// replaces it, and the chat then reads what replaced it).
    private var readsNotebookSelectionLive: Bool {
        readsNotebookTicksLive && linkedResearchNotebook != nil
            && manager.currentSessionID == nil && manager.chatMessageCount == 0
    }

    /// The notebook a new chat this pane opens on its own — a Reader
    /// passage, Walk Through, What's New, Find directions, a reset that names
    /// no Notebook — is filed in: the active notebook its window holds
    /// (`StudioViewModel.newChatNotebookID`), so reopening that chat later
    /// brings the window back to the notebook rather than out of it. Nil
    /// outside a notebook, and for a comparison pane, whose chats are not
    /// the window's. A library chat asked for from a notebook window
    /// (`requestBlankReviewChat()`) has left the notebook before it gets here.
    var windowNotebookForNewChat: String? {
        guard acceptsGlobalNavigationRequests, let windowState else { return nil }
        return vm.newChatNotebookID(in: windowState)
    }

    /// Opens a saved chat picked inside this pane — the previous-chats
    /// popover, the idle "Resume …" suggestion. The window's primary pane
    /// asks as the rail does (`requestResumeReviewSession`), so the chat-home
    /// rule applies and the open goes through the session store's guards; a
    /// comparison pane, whose chat is not the window's, opens it itself.
    @MainActor
    func openPickedSession(_ session: ReviewSessionRecord) async {
        guard acceptsGlobalNavigationRequests, let windowState else {
            await openSessionFromHistory(session)
            return
        }
        vm.inWindow(windowState) { vm.requestResumeReviewSession(session.id) }
    }

    /// Files an empty chat in the notebook its window holds, reading the
    /// notebook's ticks live (nothing is written until the learner acts). Only
    /// a chat with nothing in it, nothing on its way into it (a resume, a
    /// fresh-chat request, a passage), and filed elsewhere or nowhere: a
    /// conversation keeps where it is filed.
    private func adoptWindowNotebookIfIdle(_ notebookID: String?) {
        guard acceptsGlobalNavigationRequests,
              let notebookID, linkedResearchNotebookID != notebookID,
              // An archived notebook's chats are the library's.
              vm.notebooks.contains(where: { $0.id == notebookID }),
              vm.reviewChatResetRequestID == nil,
              !isResumePending, !sessionStore.isOpeningChat, !hasPendingComposerContext,
              manager.currentSessionID == nil, !manager.sessionActive,
              manager.chatMessageCount == 0, manager.linkedSourceIDs.isEmpty,
              manager.walkthroughPlayback == nil else { return }
        linkedResearchNotebookID = notebookID
        readsNotebookTicksLive = true
    }

    /// The first act in a chat that reads its notebook's ticks live writes
    /// them into the chat's context, as a New chat in the notebook does from
    /// the start — so what is sent, loaded and listed is that set.
    func adoptLiveNotebookSelection() {
        defer { readsNotebookTicksLive = false }
        guard readsNotebookSelectionLive, let notebook = linkedResearchNotebook else { return }
        vm.setContextSources(vm.notebookChatSourceIDs(notebook))
    }

    /// Whether this panel acts on the app-wide chat requests right now: it must
    /// be a primary panel, and the pending request must be for its window.
    var acceptsGlobalRequests: Bool {
        acceptsGlobalNavigationRequests
            && vm.chatPaneAcceptsGlobalRequests(ownerWindowID: ownerWindowID)
    }

    var requestedResumeSessionID: String? {
        sessionStore.requestedSessionID
            ?? (acceptsGlobalRequests ? vm.reviewChatResumeSessionID : nil)
    }

    /// Sources whose text is actually in the model's context right now,
    /// because the learner dropped them in or the assistant went and read
    /// them. Grows during a conversation.
    var loadedSources: [StudioArticle] {
        reviewSources.filter { manager.loadedSourceIDs.contains($0.id) }
    }

    var reviewChatDropTypes: [UTType] {
        [.studioArticle, .studioArtifact, .studioSourceID, .studioGroup, .plainText]
            + supportedBookImportDropTypes
            + Self.chatImageDropTypes
    }

    /// Picture types a chat takes from Finder, a browser, or a screenshot,
    /// attached to the next message rather than imported as a source. Named
    /// concretely rather than as `.image`: the AppKit catcher matches pasteboard
    /// types by exact identifier, and a browser's drag says `public.tiff`, not
    /// `public.image`.
    static let chatImageDropTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .webP, .heic, .heif, .bmp]

    /// What the AppKit destination laid over this panel takes before the
    /// transcript's web views or the composer's text view can: the app's own
    /// payloads and a Finder file, whose content types all ride on `.fileURL`.
    /// Dragged text is left out on purpose — the text view inserts it where
    /// the caret is, which `handleDrop` cannot. See `StudioDropCatcher`.
    private var reviewChatCaughtDropTypes: [UTType] {
        [.studioArticle, .studioArtifact, .studioSourceID, .studioGroup, .fileURL]
            + Self.chatImageDropTypes
    }

    var linkedResearchNotebook: LearningGoalRecord? {
        guard let linkedResearchNotebookID else { return nil }
        return vm.notebooks.first { $0.id == linkedResearchNotebookID }
    }

    /// The chat's notebook as its citations read it (`ChatNotebookCitations`):
    /// whether it holds a cited source, named as the Sources list names it,
    /// and Add to Notebook through the notebook write every Add to Notebook
    /// uses, which hands a team notebook the team's copy.
    var notebookCitations: ChatNotebookCitations? {
        guard let notebook = linkedResearchNotebook else { return nil }
        let notebookID = notebook.id
        let vm = vm
        let holds: @MainActor (String) -> Bool = { articleID in
            vm.notebookMembership(of: [vm.canonicalSourceID(articleID)], in: notebookID) == .all
        }
        var add: (@MainActor (String) async -> Void)?
        if vm.importableNotebook(notebookID) != nil {
            add = { token in
                guard let article = await vm.persistedArticle(forLinkToken: token) else {
                    vm.showToast("Source not found in library")
                    return
                }
                _ = await vm.addSourcesToNotebookContext([article.id], notebookID: notebookID)
            }
        }
        return ChatNotebookCitations(
            notebookID: notebookID,
            revision: "\(notebookID)#\(vm.notebookMembershipRevision)",
            holds: holds,
            add: add
        )
    }

    /// The linked notebook and the sources its ticked boxes give a new chat,
    /// watched so a chat not yet sent follows the boxes.
    private struct NotebookChatSelectionKey: Equatable {
        let notebookID: String
        let sourceIDs: [String]
    }

    private var notebookChatSelectionKey: NotebookChatSelectionKey? {
        linkedResearchNotebook.map {
            NotebookChatSelectionKey(notebookID: $0.id, sourceIDs: vm.notebookChatSourceIDs($0))
        }
    }

    /// "8 of 12" beside the notebook's name when this chat reads fewer of the
    /// notebook's sources than it has — its own and those of the context
    /// notebooks put in (`notebookChatPool`) — counting only sources a chat
    /// could read; nil otherwise, so an untouched notebook's chip shows no
    /// count. What the chat has read in stays the "in context" chip's job.
    var notebookSelectionSummary: String? {
        guard let notebook = linkedResearchNotebook else { return nil }
        let pool = vm.notebookChatPool(notebook).filter { id in
            guard let article = vm.articlesById[id] else { return false }
            return vm.isSourceIncludedInKnowledge(article)
        }
        let held = Set(reviewSources.map(\.id))
        let inChat = pool.filter(held.contains).count
        guard !pool.isEmpty, inChat < pool.count else { return nil }
        return "\(inChat) of \(pool.count)"
    }

    /// Where the open chat is filed in storage, read off the rail's records:
    /// `.some(notebookID)`, or `.some(nil)` for the ungrouped Chats list. nil
    /// while no saved chat is open or its record has not loaded yet, so there
    /// is nothing to follow.
    private var filedNotebookID: String?? {
        guard let sessionID = manager.currentSessionID,
              let record = vm.reviewSessionLinks.first(where: { $0.id == sessionID }) else { return nil }
        return .some(record.goalID)
    }

    var synthesisNotebook: LearningGoalRecord? {
        linkedResearchNotebook
    }

    var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { setDropTargeted($0) }
        )
    }

    /// The composer card's radius, shared with the drop target drawn over it so
    /// the dashed outline sits exactly on the card's edge.
    static let composerCornerRadius: CGFloat = StudioDesign.Chat.composerCornerRadius

    /// Whether the composer should read as a drop target: a source is in flight
    /// somewhere in the window, or something the app can't see the payload of
    /// (a Finder file, dragged text) is already over the chat.
    ///
    /// A pane drag goes to the edge split and a chat drag opens its own pane;
    /// neither is something this panel can take, so it stays out of their way.
    var showsComposerDropTarget: Bool {
        if isDropTargeted { return true }
        return dragVisibility.isDragging
            && !dragVisibility.isPaneDrag
            && dragVisibility.draggedSessionID == nil
    }

    /// Names what the in-flight drag is carrying, so the composer says which
    /// source it is about to take rather than only that it takes something.
    /// Nil when the payload came from outside the app.
    var draggedPayloadDescription: String? {
        if let artifactID = dragVisibility.draggedArtifactID {
            guard let artifact = vm.artifacts.first(where: { $0.id == artifactID }) else { return nil }
            return quotedDragTitle(artifact.title)
        }
        if let groupName = dragVisibility.draggedGroupName,
           !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A book, course, meeting, or playlist group is keyed by an opaque
            // ID, so the drag payload's group name is not something to show.
            // With no title resolved, say nothing rather than name an ID.
            guard let title = vm.groupDisplayTitle(groupName) else { return nil }
            return quotedDragTitle(title)
        }
        let ids = dragVisibility.draggedArticleIds
        if ids.count > 1 { return "\(ids.count) sources" }
        guard let id = ids.first, let article = vm.articlesById[id] else { return nil }
        return quotedDragTitle(vm.displayTitle(for: article))
    }

    /// A title short enough to leave "into this chat" on the same line. Trimmed
    /// here rather than by `lineLimit`, which would truncate the sentence
    /// itself and lose what the drop actually does.
    private func quotedDragTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this source" }
        guard trimmed.count > 42 else { return "“\(trimmed)”" }
        let clipped = trimmed.prefix(42).trimmingCharacters(in: .whitespaces)
        return "“\(clipped)…”"
    }

    var defaultInitialPrompt: String { "" }

    var body: some View {
        popoverLayout
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsAvailableSpace ? .infinity : nil,
            alignment: .bottom
        )
        // Words selected in a reply of this transcript act on this pane,
        // whichever window or pane the transcript is in: quoted into its
        // composer, expanded under their reply, or asked about in a side chat
        // over them.
        .environment(\.chatSelectionAction, ChatSelectionAction { action, passage, messageID, anchor in
            handleReplySelection(action, passage: passage, messageID: messageID, anchor: anchor)
        })
        // In a notebook's chat, its citations of sources the notebook does
        // not hold are marked, with Add to Notebook beside their row.
        .environment(\.chatNotebookCitations, notebookCitations)
        // The open side chat, for the reply row that hangs its popover.
        .environment(\.chatReplySideChat, replySideChat.map { model in
            ChatReplySideChatPresentation(
                model: model,
                dismiss: { closeReplySideChat(model) },
                continueInChat: { continueReplySideChatInNewChat(model) }
            )
        })
        // The preview under a browser step opens the chat's tab in the
        // Browser pane of the window that holds it.
        .environment(\.chatBrowserReveal, ChatBrowserRevealAction { revealChatBrowserTab() })
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            chatPanelWidth = width
        }
        .background {
            // Spans the panel so a trackpad pinch here moves this chat's own
            // zoom — this panel's, not every chat's — even when a reader, which
            // owns the pinch over its document, is visible beside it.
            ChatZoomShortcutTarget(
                step: { delta in stepChatZoom(by: delta) },
                reset: { sessionStore.chatZoomOffset = 0 }
            )
        }
        .contentShape(Rectangle())
        // A drop still lands anywhere over the chat, but only the composer says
        // so (`ReviewChatComposerDropTarget`). A pane-wide dashed outline would
        // name neither the payload nor the place to let go, and would light up in
        // step with every other drop zone in the window.
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
        // The `.onDrop` above, and the ones on the transcript and composer, are
        // only consulted once no AppKit view under the pointer takes the drag —
        // and the transcript's web views take every drag over them, the
        // composer's text view any with a string or file promise on it, which
        // every source drag has. So a doc or source let go over either never
        // arrived; only a drop on the panel's chrome did. This exact-type
        // destination over the whole panel is the one that takes them, and it
        // drives the same targeted state and the same `handleDrop`.
        .overlay {
            StudioDropCatcher(
                types: reviewChatCaughtDropTypes,
                declinesDragsFromWithin: true,
                onTargeted: setDropTargeted,
                onDrop: handleDrop
            )
        }
        .sheet(item: $slashSourcePickerRequest) { request in
            ArtifactSourcePicker(initial: [], seed: request.seed, purpose: .chat) { tokens in
                Task { await addSourceTokensToChatContext(tokens) }
            }
        }
        .task(id: requestedResumeSessionID) {
            await resumeRequestedSessionIfNeeded()
        }
        .task {
            // The learner's skills are `/` commands in this composer.
            await SkillLibrary.shared.loadIfNeeded()
        }
        .task(id: vm.reviewChatResetRequestID) {
            guard acceptsGlobalRequests else { return }
            resetRequestedChatIfNeeded()
        }
        // The canvas's questions are for the empty chat only. A source's text
        // loading into it (a card added from the canvas) hides the welcome for
        // a moment without the chat having anything in it.
        .onChange(of: showsIdleWelcome) { _, isShown in
            if !isShown, !manager.isSearching, !canvasSuggestedQuestions.isEmpty { canvasSuggestedQuestions = [] }
        }
        .task(id: vm.reviewChatAutoStartRequestID) {
            guard acceptsGlobalRequests else { return }
            guard vm.reviewChatAutoStartRequestID != nil else { return }
            await startRequestedReviewChat()
            vm.reviewChatAutoStartRequestID = nil
        }
        .task(id: vm.reviewSessionsRevealRequestID) {
            guard acceptsGlobalRequests else { return }
            guard vm.reviewSessionsRevealRequestID != nil else { return }
            isSessionBrowserPresented = true
            vm.reviewSessionsRevealRequestID = nil
        }
        .task(id: vm.readerSelectionExplanationRequest?.id) {
            guard acceptsGlobalRequests else { return }
            await handleReaderSelectionExplanationRequest()
        }
        // Walk Through on a source: the chat beside the Reader plays its
        // walkthrough (walkthrough-design.md, "the panel becomes a chat").
        .task(id: vm.readerWalkthroughPlayRequest?.revision) {
            guard acceptsGlobalRequests else { return }
            await handleWalkthroughPlayRequest()
        }
        // The chat points the Reader through the Studio model, which the
        // manager does not hold: every pane showing a manager lends it its own.
        .task(id: ObjectIdentifier(manager)) {
            manager.walkthroughFocusHandler = { focus in vm.applyWalkthroughReaderFocus(focus, in: windowState) }
            manager.teachBackStarter = { notebookID in pendingTeachBackNotebookID = notebookID }
            // A step or a focused panel is enlarged in the row only when no
            // Reader in this window already shows the source outlined beside
            // the chat. Only the active tab of a group mounts, so a Reader
            // behind another tab is not on screen and the lens stays.
            let windowState = windowState
            // A chat pointing at a figure of a paper no Reader here shows
            // opens it beside itself first. Only a chat in a Studio window
            // has a Reader beside it to open; a popped-out chat does not.
            if let windowState {
                manager.readerBesideChatOpener = { @MainActor [weak manager] sourceID in
                    let companion: StudioCenterTab = windowState.chatSessionID == manager?.currentSessionID
                        ? .chat : .secondaryChat
                    return await vm.openSourceBesideChat(sourceID, beside: companion, in: windowState)
                }
            } else {
                manager.readerBesideChatOpener = nil
            }
            // A Notebook this chat made has taken it in: the window opens the
            // Notebook with the chat in it, its turn still running. A chat in
            // the window's second slot is filed and stays where it is, so the
            // chat in the first slot is never swapped out from under it.
            if let windowState {
                manager.notebookWithThisChatOpener = { @MainActor notebookID, sessionID in
                    // Made a moment ago over the tool rail, so neither the
                    // Notebook nor this chat's filing has reached the model yet.
                    await vm.loadLearningGoals()
                    if !vm.reviewSessionLinks.contains(where: { $0.id == sessionID }) {
                        await vm.loadReviewSessionLinks()
                    }
                    if windowState.chatSessionID == sessionID {
                        await vm.refileChat(sessionID, inNotebook: notebookID, in: windowState)
                    } else {
                        await vm.moveReviewSession(sessionID, toNotebook: notebookID)
                    }
                }
            } else {
                manager.notebookWithThisChatOpener = nil
            }
            manager.walkthroughReaderShowsSource = { sourceID in
                (windowState?.readerSourceIDsOnScreen.contains(sourceID) ?? false)
                    || (windowState?.linkedArtifactIDsOnScreen.contains(sourceID) ?? false)
            }
            // "Figure 2D" with a paper open beside the chat means that paper,
            // dragged into the chat or not: the chat can look at the panes.
            manager.openPanesProvider = { [weak manager] in
                ChatOpenPanes.studio(
                    chatWindow: windowState,
                    chatSessionID: manager?.currentSessionID,
                    vm: vm
                )
            }
            // A question typed beside a playing video pauses it at the moment
            // the learner is asking about.
            manager.videoPauser = { sourceID in
                vm.requestReaderVideoPause(for: sourceID)
            }
        }
        // A walkthrough written again, or an animation arriving behind the
        // steps, changes the record a playing chat holds.
        .task(id: vm.readerWalkthroughRevision) {
            guard manager.walkthroughPlayback != nil else { return }
            await manager.reloadWalkthrough()
        }
        .sheet(item: $expandedWalkthroughAnimation) { animation in
            WalkthroughAnimationSheet(title: animation.title, content: animation.content)
        }
        .newNotebookFromChat($notebookFromChatRequest, vm: vm, window: windowState)
        // Pane-scoped, so every pane runs it: the handoff was addressed to
        // this pane's store by whoever asked for the new chat.
        .task(id: sessionStore.pendingNewChatHandoff?.id) {
            await handleNewChatHandoff()
        }
        // What the learner highlights on a Page beside this chat (or attached
        // to it) shows as the composer's quote, and goes with the next message.
        // A small view of its own observes the highlight, so dragging one out
        // never re-renders this pane.
        .background {
            PageSelectionQuoteMirror { mirrorPageSelection($0) }
        }
        .task(id: vm.pendingChatDocAttachment?.id) {
            guard acceptsGlobalRequests else { return }
            guard let doc = vm.pendingChatDocAttachment else { return }
            manager.addContextDoc(doc)
            vm.pendingChatDocAttachment = nil
        }
        // Cards of the canvas this chat sits beside (Add to Chat) join the
        // conversation it shows. A fresh chat asked for with them takes them
        // as it starts (`resetRequestedChatIfNeeded`), after it has cleared.
        .task(id: vm.pendingChatCanvasCards?.id) {
            guard acceptsGlobalRequests, vm.reviewChatResetRequestID == nil,
                  let handOff = vm.pendingChatCanvasCards,
                  windowState == nil || windowState?.id == handOff.windowID else { return }
            vm.pendingChatCanvasCards = nil
            await takeCanvasCards(handOff)
        }
        // Keyed on both: the session changes when a chat is opened or started,
        // and the revision changes when this pane's own send writes a link into
        // the session it is already showing.
        .task(id: ChatDocLinkKey(
            sessionID: manager.currentSessionID,
            revision: vm.artifactChatLinksRevision
        )) {
            await reloadSessionDocLinks()
        }
        .task {
            await vm.loadLearningGoals()
            await vm.refreshMemoryCompanionPlan(surfaceErrors: true)
            await syncSynthesisToolContext()
        }
        .task(id: manager.pendingSynthesisToolCall?.id) {
            guard let call = manager.pendingSynthesisToolCall else { return }
            await executeSynthesisToolCall(call)
        }
        .onChange(of: vm.notebooks) { _, notebooks in
            // After a relaunch the window's notebook can come back before
            // its record has loaded.
            adoptWindowNotebookIfIdle(windowState?.NotebookID)
            guard let linkedResearchNotebookID else { return }
            if !notebooks.contains(where: { $0.id == linkedResearchNotebookID }) {
                self.linkedResearchNotebookID = nil
            }
            Task { await syncSynthesisToolContext() }
        }
        .onChange(of: linkedResearchNotebookID) { _, _ in
            Task { await syncSynthesisToolContext() }
        }
        // A box ticked or unticked in the notebook reaches a chat not yet
        // sent in it; a chat under way keeps the catalog it began with. A
        // saved chat still being opened into this pane is under way: its
        // empty manager only looks unsent until the restore lands
        // (memory/chat-behaviour-rules.md, the restore race).
        .onChange(of: notebookChatSelectionKey) { old, new in
            // A chat reading its notebook's ticks live follows them already.
            guard acceptsGlobalRequests, !readsNotebookSelectionLive,
                  let old, let new, old.notebookID == new.notebookID,
                  !isResumePending, !sessionStore.isOpeningChat,
                  manager.currentSessionID == nil, !manager.sessionActive,
                  manager.chatMessages.isEmpty, manager.linkedSourceIDs.isEmpty else { return }
            vm.followNotebookSelection(from: old.sourceIDs, to: new.sourceIDs)
        }
        // The shared context changed in this window — its Sources list's Add
        // to Chat, a course page's — so a chat reading its notebook's ticks
        // live reads what replaced them. Another window's chat seeding the
        // shared context is not this learner acting, and changes nothing here.
        .onChange(of: vm.contextSourcesWrite) { _, write in
            guard readsNotebookTicksLive, let windowState, write.windowID == windowState.id else { return }
            readsNotebookTicksLive = false
        }
        // A source left out of this chat with its chip's × is left out while
        // it stays open; once it leaves the window, opening it again is
        // asking about it again, so the chat sees it and its chip is back.
        .onChange(of: openKeysBesideChat, initial: true) { _, ids in
            manager.keepOnScreenSourcesLeftOut(within: Set(ids))
        }
        // An empty chat in a window that holds a notebook is that notebook's:
        // a relaunch brings the notebook back with a blank chat, and a New
        // chat in a notebook window is the notebook's.
        .onChange(of: windowState?.NotebookID, initial: true) { _, notebookID in
            adoptWindowNotebookIfIdle(notebookID)
        }
        // A saved chat moved between Notebooks while it is open here — from the
        // sidebar's Move to Notebook, a drop on a Notebook folder, or over MCP —
        // is followed by the pane: the Notebook chip, the Notebook's instructions
        // and files, and the manager's tool scope change with the filing. The
        // chat's sources do not; where a chat is filed says nothing about what
        // it holds. `initial`, because the pane is built again whenever its
        // window enters or leaves a notebook, and a saved chat shown by the
        // new pane is filed where it was.
        .onChange(of: filedNotebookID, initial: true) { _, filed in
            guard let filed, manager.currentSessionID != nil else { return }
            let resolved = filed.flatMap { vm.notebook(id: $0) != nil ? $0 : nil }
            guard resolved != linkedResearchNotebookID else { return }
            linkedResearchNotebookID = resolved
            manager.setNotebookScope(resolved)
        }
        .onAppear {
            restoreDraftForCurrentScope()
            // Starts the usage listener before any request can run, so the
            // context gauge's cache figures aren't blank until the second turn.
            ChatUsageLiveMonitor.shared.start()
            Task { await syncSynthesisToolContext() }
        }
        .onChange(of: manager.chatMessageCount) { _, _ in
            refreshDefaultDraft()
        }
        // A chat becomes a stored record the moment its first message creates
        // the session row — well before the answer lands. Load the links right
        // then so the rail lists the chat while it is still generating, rather
        // than only once the turn finishes. Resuming an existing chat is
        // already in the list and skips the reload.
        .onChange(of: manager.currentSessionID) { _, sessionID in
            guard let sessionID,
                  !vm.reviewSessionLinks.contains(where: { $0.id == sessionID }) else { return }
            Task { await vm.loadReviewSessionLinks() }
        }
        .onChange(of: manager.isGenerating) { wasGenerating, isGenerating in
            guard wasGenerating, !isGenerating else { return }
            // The answer that asked for the Feynman Technique has ended: it
            // opens now, as a new chat, so that answer is not cut off.
            if let notebookID = pendingTeachBackNotebookID {
                pendingTeachBackNotebookID = nil
                if let notebook = vm.notebook(id: notebookID) {
                    Task { await startNotebookTeachBackFromIdle(notebook) }
                }
            }
        }
        // The day's goal clock runs while a memory chat is on screen here and
        // stops when it leaves, whether by closing, by switching chats, or by
        // the pane showing something else.
        .onAppear { updateMemoryGoalPresence(sessionID: manager.currentSessionID) }
        .onDisappear { MemoryReviewEngagementTracker.shared.dismiss(panel: memoryGoalPanelToken) }
        .onChange(of: manager.currentSessionID) { previousSessionID, sessionID in
            updateMemoryGoalPresence(sessionID: sessionID)
            leaveMemoryReviewFocusIfMovedOff(from: previousSessionID, to: sessionID)
            // The token outlives a send now, so it must not follow the learner
            // into another chat, nor may the reply it was about.
            isSideQuestionMode = false
            sideQuestionTarget = nil
            laneExpansionRequest = nil
            // Nor does a question waiting for its guess, or the ⋯'s Context
            // and Cost… asked of the chat before.
            pendingGuessedQuestion = nil
            isContextBreakdownRequested = false
        }
        .overlay {
            if let celebration = goalTracker.celebration,
               celebration.sessionID == manager.currentSessionID {
                MemoryGoalCelebrationView(goalMinutes: celebration.goalMinutes, streak: celebration.streak) {
                    goalTracker.acknowledgeCelebration(celebration.id)
                }
                .transition(.opacity)
                .accessibilityIdentifier("mac.chatMemoryGoalCelebration")
            }
        }
        .onDisappear {
            dropTargetResetTask?.cancel()
            manualDictationTranscriptionTask?.cancel()
            manualDictationTranscriptionTask = nil
            dictation.cancelRecording()
            speech.stop()
        }
        .onChange(of: dragVisibility.isDragging) { _, isDragging in
            guard !isDragging else { return }
            dropTargetResetTask?.cancel()
            isDropTargeted = false
        }
    }

    /// Gutter the chat header keeps outside its reading column.
    let chatHeaderGutter: CGFloat = 14

    /// Hit target of the header's own trailing control.
    let chatHeaderControlSize: CGFloat = 28
}
