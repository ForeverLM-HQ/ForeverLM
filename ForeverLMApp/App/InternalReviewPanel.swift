import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

enum ManualDictationResultDestination {
    case draft
    case send
}

/// Backdrop for the scrolling transcript. In the docked Chat column and pop-out
/// window (`flat`) messages scroll directly on the panel's window background — the
/// clean, cardless look of Claude desktop / Codex. In the floating popover the
/// glass card stays, so the transcript reads against arbitrary Studio content behind it.
private struct TranscriptSurface: ViewModifier {
    let flat: Bool

    func body(content: Content) -> some View {
        if flat {
            content
        } else {
            content.reviewGlassSurface(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: ReviewGlassStyle.composerTint,
                fallbackMaterial: .regularMaterial,
                fallbackBorder: Color.primary.opacity(0.08),
                shadowColor: Color.black.opacity(0.06),
                shadowRadius: 12,
                shadowY: 4
            )
        }
    }
}

/// Suggestion rows the learner has hidden from the idle chat.
///
/// Keys name *what* a suggestion points at — today's date, a session id, the
/// source in the reader — never just its category, so hiding a row declines that
/// specific nudge instead of switching a whole kind of suggestion off forever.
/// Tomorrow's schedule, a newer session, or a different source each produce a
/// fresh key and surface again.
///
/// UserDefaults only: this is view chrome, not knowledge-base data, so it
/// deliberately stays out of the sync pipeline. Keys are held most-recent-first
/// and trimmed at `capacity` — the per-source keys would otherwise grow with the
/// library, and a dismissal aging out after dozens of newer ones is fine.
@MainActor
@Observable
final class IdleSuggestionDismissals {
    static let shared = IdleSuggestionDismissals()
    private static let defaultsKey = "chat.dismissedIdleSuggestions"
    private static let capacity = 60

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private(set) var keys: [String]

    private init() {
        keys = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Scope component for suggestions about *today's* plan, so hiding one
    /// clears today's nudge rather than every future one.
    static func dayScope(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func isDismissed(_ key: String) -> Bool {
        keys.contains(key)
    }

    func dismiss(_ key: String) {
        guard !keys.contains(key) else { return }
        var updated = keys
        updated.insert(key, at: 0)
        if updated.count > Self.capacity {
            updated.removeLast(updated.count - Self.capacity)
        }
        persist(updated)
    }

    /// Brings every hidden suggestion back. The idle state's restore link is the
    /// only way out of a fully dismissed stack, so this has to stay reachable
    /// from the UI — otherwise dismissing the last row is a dead end.
    func restoreAll() {
        guard !keys.isEmpty else { return }
        persist([])
    }

    private func persist(_ updated: [String]) {
        keys = updated
        UserDefaults.standard.set(updated, forKey: Self.defaultsKey)
    }
}

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
            expandsChatContent: expandsChatContent,
            acceptsGlobalNavigationRequests: acceptsGlobalNavigationRequests,
            ownerWindowID: ownerWindowID,
            onOpenNewChatBeside: onOpenNewChatBeside,
            presentation: presentation
        )
        .id(ObjectIdentifier(sessionStore.activeManager))
    }
}

private struct InternalReviewPanelContent: View {
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
    var expandsChatContent: Bool
    var acceptsGlobalNavigationRequests: Bool
    var ownerWindowID: UUID?
    var onOpenNewChatBeside: ((ReaderSelectionExplanationRequest) -> Void)?
    var presentation: ChatPanelPresentation

    /// The page side chat's card, when this panel is drawn as one.
    private var pageSideChat: PageSideChatPresentation? {
        guard case .pageSideChat(let card) = presentation else { return nil }
        return card
    }

    @Environment(StudioViewModel.self) private var vm
    /// The window this pane sits in, for which sources its Readers have on
    /// screen. Optional: a chat hosted outside a Studio window has no Reader
    /// beside it, and a played step then keeps its lens.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep
    private let dragVisibility = StudioDragVisibility.shared
    /// The daily time budget, which is also the day's goal; the idle screen's
    /// Memory check row says how long the review is planned to take, and the
    /// Memory row's badge counts the same number down.
    @SyncedStorage(wrappedValue: MemoryReviewBudget.defaultMinutes, MemoryReviewBudget.preferenceKey)
    private var memoryBudgetMinutes: Int
    /// This panel's identity with the day's goal clock, minted once per view.
    /// The review moves between hosts when the window gives itself over to it
    /// and back, which builds a new panel around the same session manager
    /// before the old one goes away; a token per panel keeps the departing one
    /// from cancelling the arriving one's registration.
    @State private var memoryGoalPanelToken = UUID()
    /// Unread sources nearest to recent reading, best first, for the empty
    /// chat's "Read next" row. Found off-main each time the welcome appears.
    @State private var readNextSuggestions: [ReadNextSuggestion] = []
    /// Three questions drawn from the canvas this chat was opened beside, for
    /// the empty state (`StudioViewModel.openChatBesideKnowledgeMap`); gone
    /// once the chat has anything in it.
    @State private var canvasSuggestedQuestions: [String] = []
    @StateObject private var dictation = ReviewDictationService()
    @StateObject private var speech = ReviewSpeechService()
    @State private var voiceConversationEnabled = false
    /// The composer's text and popup state, observed only by the composer views.
    /// The pane reads it from actions, never in its body, so typing does not
    /// re-render the transcript. See `ReviewComposerDraft`.
    @State private var composer = ReviewComposerDraft()
    /// Skip was pressed and its message has not gone out yet: the footer's
    /// icon hides, so a second click cannot skip the next question too.
    @State private var isSkippingQuizQuestion = false
    @State private var manualDictationTranscriptionTask: Task<String?, Never>?
    @State private var manualDictationResultDestination: ManualDictationResultDestination?
    @State private var lastSpokenAssistantMessageID: UUID?
    /// Which source each `[n]` in this transcript names, and whose card the
    /// conversation has already shown. A row cannot work its own out — the
    /// answer depends on every reply above it — so the transcript stack rebuilds
    /// it here whenever the set of replies changes. See `ChatCitationLedger`.
    @State private var citationContexts: [UUID: ChatCitationLedger.MessageContext] = [:]
    @State private var voiceScheduleChoices: [SchedulePlanItem] = []
    @State private var voiceScheduleChoicesDate = Date()
    @State private var preserveCurrentSpeechOnVoiceModeDisable = false
    @State private var isDropTargeted = false
    @State private var dropTargetResetTask: Task<Void, Never>?

    @State private var isSessionBrowserPresented = false
    @State private var linkedResearchNotebookID: String?
    /// Set when a notebook opening in this window started this chat
    /// (`StudioViewModel.pendingNotebookChatRequestID`), or an idle chat
    /// joined its window's notebook. Until the learner acts here, the chat
    /// reads its notebook's ticked sources live rather than the shared
    /// context, because opening a notebook writes nothing; the first thing
    /// the learner does here adopts them (`adoptLiveNotebookSelection`).
    /// Only this window ends it: its own setting of the context, here or
    /// from its sidebar (`contextSourcesWrite`). Another window's chat
    /// seeding the shared context does not.
    @State private var readsNotebookTicksLive = false
    /// Bumped when the notebook's kept questions change, so its guide reads
    /// them again (`NotebookSuggestedQuestionRows` live in the defaults).
    @State private var notebookQuestionsRevision = 0
    @State private var isContextSourcesPopoverPresented = false
    @State private var isContextSourcesChipHovering = false
    /// The ⋯'s Context and Cost…: the composer draws its context ring,
    /// although the window is not yet filling up, and the ring opens its
    /// breakdown; the ring sets this back once the breakdown closes.
    @State private var isContextBreakdownRequested = false
    /// The chat's title is a field: Codex's rename, from a click on the title
    /// or the header's Rename….
    @State private var isRenamingChatTitle = false
    @State private var chatTitleDraft = ""
    @FocusState private var chatTitleFieldFocused: Bool
    /// New Notebook from This Chat, asked from the notebook picker or ⋯.
    @State private var notebookFromChatRequest: NotebookFromChatRequest?
    /// The composer sends the next message as a side question: an aside about
    /// a reply that the tutor answers without moving the conversation on, and
    /// without grading while a question is open. Set from the footer icon on
    /// any reply, shown as a token at the head of the field, and off again
    /// once the learner answers or takes it off.
    @State private var isSideQuestionMode = false
    /// Think first's chat moment (docs/fences-and-think-first-design.md): a
    /// question the learner sent in a notebook's chat, held while the field
    /// asks "Your guess first?". Return sends it with the guess, the token's ×
    /// or Escape sends it at once.
    @State private var pendingGuessedQuestion: ComposedChatSend?
    /// The composer holds Generate's "I want to make a course about " and
    /// the message it becomes goes with the course-planning instructions
    /// (`CoursePlanningChat`). Cleared with the composer, so a chat the
    /// learner moved on to never inherits them.
    @State private var coursePlanningArmed = false
    /// The reply the armed side question is about. Nil with the token off, or
    /// when ⌥Return sends one without arming: then it is the newest reply.
    @State private var sideQuestionTarget: ReviewChatReplyReference?
    /// The side chat open over words selected in one of this transcript's
    /// replies, while it is open. One at a time: a second selection's side
    /// chat takes the first one's place.
    @State private var replySideChat: ChatReplySideChatModel?
    /// More details pressed on a reply whose lane already exists: the lane is
    /// asked to open rather than a second one being sent.
    @State private var laneExpansionRequest: ReviewChatLaneExpansionRequest?
    @SyncedStorage("metadataVisibility") private var metadataVisibility = MetadataVisibilitySettings()
    /// The Doc each answer went into with Save to note, by the answer's block
    /// id (a message id, so a reopened chat starts with none). In memory only.
    @State private var answerNoteDocIDs: [UUID: String] = [:]
    /// Answers whose Doc is being made, so a second click makes no second Doc.
    @State private var answersBeingSavedToNotes: Set<UUID> = []

    @State private var transcriptViewportHeight: CGFloat = 0
    /// When the current turn was sent, for the working indicator's clock. Nil
    /// whenever no turn is in flight.
    @State private var turnStartedAt: Date?
    /// Current pane width, used only to derive a responsive reading measure.
    /// The geometry callback publishes this one lightweight scalar.
    @State private var chatPanelWidth: CGFloat = 0
    /// Passage the learner chose to chat about. Attached to the next send, not auto-submitted.
    @State private var pendingReaderSelection: ReaderSelectionExplanationRequest?
    /// A walkthrough step's animation the learner asked to see larger.
    @State private var expandedWalkthroughAnimation: WalkthroughEnlargedAnimation?
    /// The walkthrough card folded to its title line, to give the chat room.
    @State private var isWalkthroughCardFolded = false
    /// The memory review card chosen with Back and Next; nil for the newest,
    /// the one being answered.
    @State private var memoryReviewCardIndex: Int?
    /// Whether a memory review is drawn as cards or as its conversation.
    @AppStorage(MemoryReviewLayout.storageKey) private var memoryReviewLayoutRaw = MemoryReviewLayout.cards.rawValue
    /// The chat panel's height, which the walkthrough card takes at most a
    /// share of.
    @State private var transcriptPanelHeight: CGFloat = 0
    /// The passage a queued message was asked about, kept so the × on its
    /// bubble can hand the passage back along with the words.
    @State private var queuedReaderSelections: [UUID: ReaderSelectionExplanationRequest] = [:]
    /// The doc passages this conversation was opened on, once they are saved.
    /// `pendingReaderSelection` is the same thing before the question is sent;
    /// these outlive the send, and the pane, and the app.
    @State private var sessionDocLinks: [ArtifactChatLink] = []

    /// The Docs source picker, opened by `/source` when the popup is not the
    /// answer — a bare command, or a search that found nothing.
    @State private var slashSourcePickerRequest: SlashSourcePickerRequest?

    private struct SlashSourcePickerRequest: Identifiable {
        let id = UUID()
        /// What the learner had typed after `/source`, prefilled into the search.
        let seed: String
    }

    /// Action-side views of the composer state. Read and written from handlers
    /// only: a read from `body` would put the whole pane back on the keystroke
    /// path, which is what `ReviewComposerDraft` exists to prevent.
    private var draft: String {
        get { composer.text }
        nonmutating set { composer.text = newValue }
    }

    /// The passage quoted out of this transcript that the next message carries.
    /// It is not part of `draft`: the composer draws it as a quote above the
    /// field, and the send folds it in as a blockquote.
    private var quotedPassage: String {
        get { composer.quotedPassage }
        nonmutating set { composer.quotedPassage = newValue }
    }

    private var lastInsertedDefaultPrompt: String? {
        get { composer.lastInsertedDefaultPrompt }
        nonmutating set { composer.lastInsertedDefaultPrompt = newValue }
    }

    private var slashSelectionIndex: Int {
        get { composer.slashSelectionIndex }
        nonmutating set { composer.slashSelectionIndex = newValue }
    }

    private let sessionBrowserPopoverWidth: CGFloat = 440
    private let sessionBrowserPopoverHeight: CGFloat = 480
    private let contextSourcesPopoverWidth: CGFloat = 380
    private let contextSourcesPopoverHeight: CGFloat = 420

    /// The empty chat's greeting keeps a focused column, and the suggestions
    /// over the composer a slightly wider one. The composer itself keeps the
    /// transcript's width (`chatColumnMaxWidth`), so the first message does not
    /// move it.
    private let idleWelcomeColumnWidth: CGFloat = 420
    private let idleComposerMaxWidth: CGFloat = 620

    /// Responsive readable cap for the chat column. A sole Chat pane follows
    /// the window at roughly 72%, bounded so neither a small nor an ultrawide
    /// window produces awkward prose. Split layouts retain the compact width
    /// they were designed around.
    private var chatColumnMaxWidth: CGFloat {
        guard expandsChatContent, chatPanelWidth > 0 else { return 700 }
        return min(1_200, max(700, chatPanelWidth * 0.72))
    }

    /// The bubble sits inside 28 points of transcript gutters and leaves a
    /// 48-point trailing breathing space for assistant turns.
    private var chatMessageMaxWidth: CGFloat {
        max(620, chatColumnMaxWidth - 76)
    }

    /// Everything attached to this chat — for a Notebook, its whole approved
    /// pool. Availability, not residency: these are the sources the assistant
    /// may reach for, and most of them are only a catalog line in the prompt.
    private var reviewSources: [StudioArticle] {
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
    private var windowNotebookForNewChat: String? {
        guard acceptsGlobalNavigationRequests, let windowState else { return nil }
        return vm.newChatNotebookID(in: windowState)
    }

    /// Opens a saved chat picked inside this pane — the previous-chats
    /// popover, the idle "Resume …" suggestion. The window's primary pane
    /// asks as the rail does (`requestResumeReviewSession`), so the chat-home
    /// rule applies and the open goes through the session store's guards; a
    /// comparison pane, whose chat is not the window's, opens it itself.
    @MainActor
    private func openPickedSession(_ session: ReviewSessionRecord) async {
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
    private func adoptLiveNotebookSelection() {
        defer { readsNotebookTicksLive = false }
        guard readsNotebookSelectionLive, let notebook = linkedResearchNotebook else { return }
        vm.setContextSources(vm.notebookChatSourceIDs(notebook))
    }

    /// Whether this panel acts on the app-wide chat requests right now: it must
    /// be a primary panel, and the pending request must be for its window.
    private var acceptsGlobalRequests: Bool {
        acceptsGlobalNavigationRequests
            && vm.chatPaneAcceptsGlobalRequests(ownerWindowID: ownerWindowID)
    }

    private var requestedResumeSessionID: String? {
        sessionStore.requestedSessionID
            ?? (acceptsGlobalRequests ? vm.reviewChatResumeSessionID : nil)
    }

    /// Sources whose text is actually in the model's context right now,
    /// because the learner dropped them in or the assistant went and read
    /// them. Grows during a conversation.
    private var loadedSources: [StudioArticle] {
        reviewSources.filter { manager.loadedSourceIDs.contains($0.id) }
    }

    private var reviewChatDropTypes: [UTType] {
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

    private var linkedResearchNotebook: LearningGoalRecord? {
        guard let linkedResearchNotebookID else { return nil }
        return vm.notebooks.first { $0.id == linkedResearchNotebookID }
    }

    /// The chat's notebook as its citations read it (`ChatNotebookCitations`):
    /// whether it holds a cited source, named as the Sources list names it,
    /// and Add to Notebook through the notebook write every Add to Notebook
    /// uses, which hands a team notebook the team's copy.
    private var notebookCitations: ChatNotebookCitations? {
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
    private var notebookSelectionSummary: String? {
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

    private var synthesisNotebook: LearningGoalRecord? {
        linkedResearchNotebook
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { setDropTargeted($0) }
        )
    }

    /// The composer card's radius, shared with the drop target drawn over it so
    /// the dashed outline sits exactly on the card's edge.
    private static let composerCornerRadius: CGFloat = StudioDesign.Chat.composerCornerRadius

    /// Whether the composer should read as a drop target: a source is in flight
    /// somewhere in the window, or something the app can't see the payload of
    /// (a Finder file, dragged text) is already over the chat.
    ///
    /// A pane drag goes to the edge split and a chat drag opens its own pane;
    /// neither is something this panel can take, so it stays out of their way.
    private var showsComposerDropTarget: Bool {
        if isDropTargeted { return true }
        return dragVisibility.isDragging
            && !dragVisibility.isPaneDrag
            && dragVisibility.draggedSessionID == nil
    }

    /// Names what the in-flight drag is carrying, so the composer says which
    /// source it is about to take rather than only that it takes something.
    /// Nil when the payload came from outside the app.
    private var draggedPayloadDescription: String? {
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

    private var defaultInitialPrompt: String { "" }

    private var reviewSubject: String {
        let types = Set(reviewSources.map(\.sourceType))
        if types.count == 1 && types.contains(.book) {
            return "these book chapter(s)"
        }
        if reviewSources.count == 1, let source = reviewSources.first {
            return "this \(contextNoun(for: source.sourceType).singular)"
        }
        if !reviewSources.isEmpty {
            if types.count == 1, let type = types.first {
                return "these \(contextNoun(for: type).plural)"
            }
            return "these sources"
        }
        return ""
    }

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
        // so (`ReviewChatComposerDropTarget`). The pane-wide dashed outline that
        // used to appear here named neither the payload nor the place to let go,
        // and it lit up in step with every other drop zone in the window.
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
            manager.walkthroughFocusHandler = { focus in vm.applyWalkthroughReaderFocus(focus) }
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
        .onChange(of: sourcesOnScreenBesideChat.map(\.id), initial: true) { _, ids in
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
            speech.onFinishSpeaking = { messageID in
                Task { @MainActor in
                    await handleAssistantSpeechFinished(messageID: messageID)
                }
            }
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
            speakLatestAssistantMessageIfNeeded()
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
        .onChange(of: voiceConversationEnabled) { _, enabled in
            handleVoiceConversationModeChange(enabled)
        }
        .onDisappear {
            dropTargetResetTask?.cancel()
            manualDictationTranscriptionTask?.cancel()
            manualDictationTranscriptionTask = nil
            dictation.cancelRecording()
            speech.stop()
            speech.onFinishSpeaking = nil
        }
        .onChange(of: dragVisibility.isDragging) { _, isDragging in
            guard !isDragging else { return }
            dropTargetResetTask?.cancel()
            isDropTargeted = false
        }
    }

    /// Chat renders at its own zoom: the app step plus whatever a pinch over
    /// this panel has added on top. Applied here rather than around the whole
    /// body so it covers everything chat draws — transcript, header, composer —
    /// while the panels beside it keep the app-wide size.
    private var popoverLayout: some View {
        Group {
            if let card = pageSideChat {
                pageSideChatLayout(card)
            } else {
                minimalAssistantLayout
            }
        }
            .dynamicTypeSize(ChatZoom.size(appStep: uiZoomStep, offset: chatZoomOffset))
            .environment(\.uiZoomScale, uiZoomScale)
    }

    /// This panel's pinch offset, held by its session store so it belongs to
    /// this chat host alone and outlives a switch to another chat here.
    private var chatZoomOffset: Int { sessionStore.chatZoomOffset }

    /// Chat's own zoom scale. Read from the stored steps rather than the
    /// environment because this view is the one that *sets* the chat scale for
    /// its subtree — the environment here still holds the app-wide value.
    private var uiZoomScale: CGFloat {
        ChatZoom.scale(appStep: uiZoomStep, offset: chatZoomOffset)
    }

    /// Move this chat one zoom step relative to the app UI. Returns false at the
    /// ends of the range so the pinch stops accumulating.
    private func stepChatZoom(by delta: Int) -> Bool {
        guard let next = ChatZoom.offset(
            stepping: delta,
            appStep: uiZoomStep,
            offset: sessionStore.chatZoomOffset
        ) else { return false }
        sessionStore.chatZoomOffset = next
        return true
    }

    private var shouldShowTranscript: Bool {
        // The count, not the messages: reading `chatMessages` here would make
        // every streamed token re-evaluate this whole panel. See
        // `ReviewChatTranscriptStack`.
        manager.chatMessageCount > 0
            || manager.isPreparingGeneration
            || manager.isSearching
            || manager.isGenerating
            // Walk Through pressed in an empty chat: the wait for the first
            // step belongs under a working line, not behind the New chat
            // welcome screen.
            || manager.walkthroughPreparationDetail != nil
            // A dealt step adds no chat turn (`playWalkthroughStep`), so a
            // walk in an empty chat has no messages to count; its deck is in
            // the transcript panel, which the welcome screen otherwise hid.
            || manager.walkthroughPlayback != nil
            // Opening a saved chat swaps in a fresh manager, which rebuilds this
            // whole panel with an empty one for a frame before the resume starts.
            // Without this the learner's click on an existing conversation flashes
            // the New chat welcome — the one screen it certainly is not.
            || isResumePending
    }

    /// A saved chat has been clicked and its transcript has not landed yet. The
    /// request outlives the manager swap, so it is the only state that spans the
    /// blank frame between the two.
    private var isResumePending: Bool {
        manager.isResumingSession
            || (requestedResumeSessionID != nil && manager.currentSessionID == nil)
    }

    /// A passage handed in from Reader or Docs makes this a contextual composer,
    /// even before the learner sends the first turn. Treating it as an idle chat
    /// leaves the unrelated greeting and suggestions competing with the passage.
    /// Include the global request so the welcome disappears on the same render
    /// that reveals Chat, without waiting for the task below to stage its chip.
    private var hasPendingComposerContext: Bool {
        pendingReaderSelection != nil
            || sessionStore.pendingNewChatHandoff != nil
            || (acceptsGlobalRequests && vm.readerSelectionExplanationRequest != nil)
    }

    /// Whether to show the idle welcome hero: a docked/pop-out panel with no
    /// conversation or handed-in context. The bottom-sheet popover keeps its
    /// compact layout.
    private var showsIdleWelcome: Bool {
        fillsAvailableSpace && !shouldShowTranscript && !hasPendingComposerContext
    }

    // MARK: - The page's side chat

    /// ChatGPT's page chat as a card (docs/pages-side-chat-design.md): a header,
    /// the transcript once a conversation exists, and the composer — this
    /// pane's own, so "+", the model, the mic, tools and citations all work.
    /// The card's frame, corners and shadow are drawn around this by
    /// `PageSideChatLayer`.
    private func pageSideChatLayout(_ card: PageSideChatPresentation) -> some View {
        VStack(spacing: 0) {
            pageSideChatHeader(card)
            if shouldShowTranscript {
                Divider()
                // A fixed region: the transcript is a web view that cannot
                // report how tall its content is (`PageSideChatLayout`).
                compactTranscriptPanel
                    .frame(height: PageSideChatLayout.transcriptHeight(paneHeight: card.paneHeight, zoom: uiZoomScale))
                Divider()
            } else if let error = manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage {
                errorText(error)
                    .padding(.horizontal, 14)
            }
            inputBar
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    /// Minimize, the chat's title with its menu, the actions (the page's chats,
    /// a new one, the way into the docked Chat pane) and the close ×.
    private func pageSideChatHeader(_ card: PageSideChatPresentation) -> some View {
        HStack(spacing: 4) {
            Button(action: card.onMinimize) {
                Image(systemName: "minus")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .buttonStyle(.hoverWash(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12))
            .help("Minimize")
            .accessibilityLabel("Minimize the page chat")
            .accessibilityIdentifier("mac.pageSideChatMinimize")

            Menu {
                pageSideChatChatsMenuItems(card)
            } label: {
                HStack(spacing: 4) {
                    Text(pageSideChatTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("This page's chats")
            .accessibilityIdentifier("mac.pageSideChatChats")

            Spacer(minLength: 0)

            Menu {
                pageSideChatActionItems(card)
            } label: {
                Image(systemName: "circle.grid.2x3.fill")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12)
            .help("More chat actions")
            .accessibilityLabel("More chat actions")
            .accessibilityIdentifier("mac.pageSideChatActions")

            // The card goes away and lets go of its chat, which stays saved
            // and listed under the page; minimize is the way to keep it.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .buttonStyle(.hoverWash(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12))
            .help("Close")
            .accessibilityLabel("Close the page chat")
            .accessibilityIdentifier("mac.pageSideChatClose")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The header's title: the chat's own, or "New chat" before it has a row.
    private var pageSideChatTitle: String { selectedChatTitle ?? "New chat" }

    /// The title's menu: this page's chats, the open one ticked, then a new
    /// chat and the docked pane.
    @ViewBuilder
    private func pageSideChatChatsMenuItems(_ card: PageSideChatPresentation) -> some View {
        if !card.chats.isEmpty {
            Section("Chats about this page") {
                ForEach(card.chats) { chat in
                    Button {
                        card.onOpenChat(chat.id)
                    } label: {
                        if chat.id == manager.currentSessionID {
                            Label(PageSideChatChats.title(of: chat), systemImage: "checkmark")
                        } else {
                            Text(PageSideChatChats.title(of: chat))
                        }
                    }
                }
            }
            Divider()
        }
        Button {
            card.onNewChat()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        pageSideChatOpenInChatButton(card)
    }

    /// The ⋮⋮ menu: the docked pane, this chat's address and its transcript.
    /// "Open in Other Window" is not here: the card shows the chat, and a
    /// second window would draw it again.
    @ViewBuilder
    private func pageSideChatActionItems(_ card: PageSideChatPresentation) -> some View {
        pageSideChatOpenInChatButton(card)
        if let sessionID = manager.currentSessionID {
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    StudioEntityLink.chat(sessionID).markdownDestination,
                    forType: .string
                )
                vm.showToast("Link copied")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Button {
                copyConversation()
            } label: {
                Label("Copy Conversation", systemImage: "doc.on.doc")
            }
            .disabled(manager.chatMessages.isEmpty)
        }
    }

    /// Moves this chat into the docked Chat pane. Between turns only: the card
    /// letting go of a running turn would stop it.
    private func pageSideChatOpenInChatButton(_ card: PageSideChatPresentation) -> some View {
        Button {
            card.onOpenInChat()
        } label: {
            Label("Open in Chat", systemImage: "arrow.up.right.square")
        }
        .disabled(manager.currentSessionID == nil || isTurnInFlight)
    }

    private var minimalAssistantLayout: some View {
        VStack(spacing: 8) {
            if shouldShowTranscript {
                compactTranscriptPanel
            }
            if showsIdleWelcome {
                // Codex's empty chat (product owner, 2026-10-11: "make the chat
                // experience more look chatgpt codex"): the heading in the
                // middle, the composer pinned to the foot where it stays once
                // the chat begins, and the few starting points just above it,
                // no card, no headers.
                Spacer(minLength: 12)
                idleWelcomeHeading
                    .transition(.opacity)
                    .task(id: vm.hasCompletedInitialQueueLoad) { await refreshReadNextSuggestions() }
                Spacer(minLength: 12)
                idleWelcomeOffers
                    .frame(maxWidth: idleComposerMaxWidth)
                    .padding(.bottom, StudioDesign.Spacing.xSmall)
                    .transition(.opacity)
            }
            if !shouldShowTranscript,
               let error = manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage {
                errorText(error)
                    .frame(maxWidth: chatColumnMaxWidth)
            }
            if let snapshot = teamSnapshotRecord {
                // A transcript a team shares is read: nobody continues it, so
                // the composer gives way to a line saying where it came from.
                sharedTranscriptFooter(snapshot)
                    .frame(maxWidth: chatColumnMaxWidth)
            } else if !hidesComposerForMemoryCard {
                // One width with or without a transcript, so the first send
                // leaves the composer where it was.
                inputBar
                    .frame(maxWidth: chatColumnMaxWidth)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowTranscript)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
    }

    // MARK: - Idle welcome (empty chat)

    /// One suggested next step shown as a row while the chat is empty. Each is
    /// backed by live app state — today's plan, the latest saved session, or the
    /// source open in the reader. The two fixed prompts are the workflows every
    /// learner starts from: planning the day and setting a goal.
    private struct IdleSuggestion: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        /// What hiding this row remembers. Scoped to the thing being suggested
        /// rather than the row's category — see `IdleSuggestionDismissals`.
        let dismissalKey: String
        let action: @MainActor () async -> Void
        /// Where the row opens something another window can show instead —
        /// a chat to resume — for its right-click Open in Other Window.
        var otherWindowDestination: StudioWindowDestination? = nil
        /// Why this row is on offer, shown on hover. Nil for rows whose
        /// title already says it.
        var help: String? = nil
        /// Today's plan: the row opens it in a popover instead of running
        /// `action`.
        var todayPlan: IdleTodayPlan? = nil
    }

    /// Today's pending planned items and what can be done with them: the
    /// Today card's, which the plan's own row opens since 2026-10-06.
    private struct IdleTodayPlan {
        let items: [SchedulePlanItem]
        let start: (SchedulePlanItem) -> Void
        let markDone: (SchedulePlanItem) -> Void
        let quiz: () -> Void
    }

    /// How many suggestions the empty chat offers under the composer: ChatGPT
    /// offers a few starting points and no more (product owner, 2026-10-06: "cleaner
    /// and fewer buttons and bells and whistles"). The rest wait their turn:
    /// hiding one brings up the next.
    static let idleSuggestionLimit = 3

    /// Names the Notebook rather than the hour. What the learner came here for is
    /// the work, not the time of day, and the Notebook name earns the largest
    /// type on an otherwise empty chat.
    ///
    /// Keyed on the Notebook this chat is *linked* to, not the one open in the
    /// Notebooks overlay: a chat that hasn't adopted it isn't working in it, and
    /// heading it with that name would misstate where answers come from.
    private var idleGreetingTitle: String {
        linkedResearchNotebook?.title ?? timeOfDayGreeting
    }

    private var timeOfDayGreeting: String {
        let base: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: base = "Good morning"
        case 12..<18: base = "Good afternoon"
        default: base = "Good evening"
        }
        guard let name = MacAccountUser.firstName else { return base }
        return "\(base), \(name)"
    }

    /// Today's plan, as its row names it: what is still planned for today,
    /// and which goal it serves. It deliberately never congratulates: the app
    /// cannot see whether anything was understood — only that no planned item
    /// is outstanding — and an empty plan is the ordinary state, not an
    /// achievement. It was the greeting's subtitle until 2026-10-06, when the
    /// welcome kept only its greeting line.
    private func idleTodayPlanTitle(_ schedule: IdleScheduleSnapshot) -> String {
        let pending = schedule.pendingToday
        let count = pending.count == 1 ? "1 source" : "\(pending.count) sources"
        let completedToday = schedule.today?.completedCount ?? 0
        let progress = completedToday > 0 ? "\(count) to go today" : "\(count) planned today"
        let goalTitles = orderedUniqueGoalTitles(in: pending)
        if goalTitles.count == 1, let goal = goalTitles.first {
            return "\(progress) for \u{201C}\(goal)\u{201D}"
        }
        return progress
    }

    private func orderedUniqueGoalTitles(in items: [SchedulePlanItem]) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for tag in items.flatMap(\.goalTags) {
            let title = tag.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            titles.append(title)
        }
        return titles
    }

    /// What the empty chat shows above the composer: in a notebook workspace,
    /// the chat filed in the window's notebook shows that notebook's heading;
    /// everywhere else the greeting.
    @ViewBuilder
    private var idleWelcomeHeading: some View {
        if let notebook = notebookGuideNotebook {
            let notebookTitle = NotebookTitle(notebook.title)
            NotebookChatGuideHeading(
                notebookID: notebook.id,
                icon: notebookTitle.displayIcon,
                title: notebookTitle.text.isEmpty ? "Untitled notebook" : notebookTitle.text,
                summary: notebook.displaySummary,
                columnWidth: idleWelcomeColumnWidth
            )
        } else {
            // The greeting alone. Its subtitle went on 2026-10-06: most days
            // it said "Ready when you are.", and the day's plan it otherwise
            // named is the first suggestion under the composer.
            Text(idleGreetingTitle)
                .font(.system(size: 24, weight: .medium, design: .serif))
                // Notebook titles run longer than "Good afternoon".
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: idleWelcomeColumnWidth)
                .frame(maxWidth: .infinity)
        }
    }

    /// What the empty chat offers under the composer: the notebook guide's
    /// chips and chats, or at most `idleSuggestionLimit` suggestions.
    @ViewBuilder
    private var idleWelcomeOffers: some View {
        if let context = manager.canvasContext {
            // A chat about a canvas: its questions, when it has any, and the
            // maps the canvas can draw from the cards.
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                if !canvasSuggestedQuestions.isEmpty {
                    canvasQuestionCards
                }
                // The Ask draws on the canvas open on this Mac: not offered
                // for another canvas's cards.
                if context.canvasID == vm.knowledgeMap.mapID {
                    KnowledgeMapChatOffers(offersQuestionMap: context.holdsQuestion) { tool in
                        vm.startCanvasAsk(tool, from: context)
                    }
                }
            }
        } else if !canvasSuggestedQuestions.isEmpty {
            canvasQuestionCards
        } else if let notebook = notebookGuideNotebook {
            notebookGuide(notebook)
        } else {
            idleSuggestions
        }
    }

    /// The questions drawn from the canvas this chat was opened beside: a
    /// click puts one in the composer, to send or to change.
    private var canvasQuestionCards: some View {
        ChatSuggestedQuestionCards(
            questions: canvasSuggestedQuestions,
            fontSize: 13,
            maxWidth: idleComposerMaxWidth,
            send: fillComposerWithCanvasQuestion
        )
        .accessibilityIdentifier("chat.canvasQuestions")
    }

    /// The composer takes the question: in place of what it holds when that
    /// is empty or was put there by the app, else on a line of its own.
    private func fillComposerWithCanvasQuestion(_ question: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = question
            lastInsertedDefaultPrompt = question
        } else {
            draft += "\n\(question)"
            lastInsertedDefaultPrompt = nil
        }
        vm.reviewChatFocusRequestID = UUID()
    }

    /// The notebook whose guide this empty chat shows: the one the chat is
    /// filed in, while its window holds that notebook.
    private var notebookGuideNotebook: LearningGoalRecord? {
        guard let notebook = linkedResearchNotebook,
              windowState?.NotebookID == notebook.id else { return nil }
        return notebook
    }

    /// The notebook guide under the composer (`NotebookChatGuide`): no model
    /// call on open — the chips that ask when pressed, and the notebook's
    /// chats. Its heading, `NotebookChatGuideHeading`, stands above the
    /// composer.
    private func notebookGuide(_ notebook: LearningGoalRecord) -> some View {
        let tally = vm.notebookChatTally(notebook)
        // Read again when this chat keeps or asks a question, or another
        // device's row arrives.
        _ = notebookQuestionsRevision
        return NotebookChatGuide(
            inChat: tally.inChat,
            total: tally.total,
            columnWidth: idleWelcomeColumnWidth,
            chats: vm.notebookChats(notebookID: notebook.id)
                .filter { $0.id != manager.currentSessionID }
                .map { NotebookChatGuide.RecentChat(id: $0.id, title: $0.title.isEmpty ? "Untitled chat" : $0.title, date: $0.createdAt) },
            questions: vm.notebookQuestionOffer(notebook),
            suggestQuestions: {
                Task { await suggestNotebookQuestions() }
            },
            askQuestion: { question in
                clearComposer()
                pendingReaderSelection = nil
                askSuggestedQuestion(question)
            },
            review: {
                Task { await startNotebookReviewFromIdle(notebook) }
            },
            openChat: { sessionID in
                if let windowState {
                    vm.inWindow(windowState) { vm.requestResumeReviewSession(sessionID) }
                } else {
                    vm.requestResumeReviewSession(sessionID)
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
            if keys.contains(where: { $0.hasPrefix(NotebookSuggestedQuestions.preferenceKeyPrefix) }) {
                notebookQuestionsRevision &+= 1
            }
        }
    }

    /// The guide's Suggest questions: the request goes out as the learner's
    /// message, and the answer's suggested questions are its cards. They are
    /// kept with the notebook, for its sources as they stand now, so the
    /// guide offers them in its next chats without asking a model again
    /// (`NotebookSuggestedQuestions`).
    @MainActor
    private func suggestNotebookQuestions() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        let notebookID = linkedResearchNotebook?.id
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(NotebookChatGuide.suggestQuestionsPrompt)
        guard let notebookID, let notebook = vm.notebooks.first(where: { $0.id == notebookID }),
              let questions = manager.chatMessages.last(where: { $0.role == .assistant })?.followUpQuestions,
              !questions.isEmpty else { return }
        vm.keepNotebookQuestions(questions, notebook: notebook)
        notebookQuestionsRevision &+= 1
    }

    /// At most `idleSuggestionLimit` suggestions under the composer, as quiet
    /// rows with no card around them and no header (2026-10-06, ChatGPT's
    /// new chat; they were a card of up to seven under a Today card), in the
    /// order `allIdleSuggestions` ranks them; the restore link once every one
    /// has been hidden.
    @ViewBuilder
    private var idleSuggestions: some View {
        let state = idleWelcomeState(idleScheduleSnapshot)
        if state.hasContent {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.suggestions) { suggestion in
                    IdleSuggestionRow(suggestion: suggestion) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            IdleSuggestionDismissals.shared.dismiss(suggestion.dismissalKey)
                        }
                    }
                }
                if state.showsRestore {
                    restoreIdleSuggestionsButton
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, StudioDesign.Spacing.small)
        }
    }

    /// Shown only once everything on offer has been hidden. Dismissals are
    /// allowed to be permanent precisely because this exists: the quietest
    /// possible way back, and absent entirely while anything is still on screen.
    private var restoreIdleSuggestionsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                IdleSuggestionDismissals.shared.restoreAll()
            }
        } label: {
            Text("Show suggestions")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .help("Bring back everything you've hidden here")
    }

    /// One suggested action as a quiet row under the composer: a bare
    /// monochrome glyph and the title in secondary type, brightening under the
    /// pointer, and a dismiss button that appears with it. No chevron, no card:
    /// ChatGPT's starting points read as text, not as a panel.
    ///
    /// The action and the dismiss are siblings sharing one background rather than
    /// nested buttons — a Button inside another Button's label swallows clicks
    /// unpredictably on macOS. The dismiss keeps its slot in the layout while
    /// invisible so the title doesn't reflow under the cursor. The row paints
    /// its own hover wash, so its action button takes `.plain`.
    private struct IdleSuggestionRow: View {
        let suggestion: IdleSuggestion
        let onDismiss: () -> Void
        @State private var isHovered = false
        @State private var isShowingTodayPlan = false

        private var dismissGlyph: some View {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 8, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }

        var body: some View {
            HStack(spacing: 0) {
                Button {
                    if suggestion.todayPlan != nil {
                        isShowingTodayPlan = true
                    } else {
                        Task { await suggestion.action() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.systemImage)
                            .zoomedSystemFont(size: 12, weight: .regular)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(suggestion.title)
                            .font(.system(size: 13))
                            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(suggestion.help ?? "")
                .accessibilityIdentifier("mac.chatSuggestion.\(suggestion.id)")
                .popover(isPresented: $isShowingTodayPlan, arrowEdge: .bottom) {
                    if let plan = suggestion.todayPlan {
                        IdleTodayPlanList(plan: plan) { isShowingTodayPlan = false }
                    }
                }

                // Built only under the pointer, so a stale tracking state can
                // never turn a click into a dismissal the learner couldn't see
                // coming, and a hidden glyph holds its place. A button at
                // opacity 0 is still a live control, and while an assistive
                // app reads the screen SwiftUI walks every control in the
                // window for each one an update builds (2026-10-03).
                Group {
                    if isHovered {
                        Button(action: onDismiss) {
                            dismissGlyph
                        }
                        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.10))
                        .help("Hide this suggestion")
                        .accessibilityLabel("Hide suggestion: \(suggestion.title)")
                    } else {
                        dismissGlyph
                            .hidden()
                    }
                }
                .padding(.trailing, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            // Right-click reaches the same dismiss without depending on hover,
            // which a keyboard- or trackpad-averse pass over the row never gets.
            .contextMenu {
                if let destination = suggestion.otherWindowDestination {
                    OtherWindowMenuItem(destination)
                    Divider()
                }
                Button("Hide This Suggestion", action: onDismiss)
            }
        }
    }

    /// The schedule facts the idle welcome is built from, resolved once per
    /// render. The greeting, the suggestions and the welcome state each used to
    /// rebucket the whole Schedule for themselves, so an empty chat rebuilt it
    /// four to six times per body pass. Pure/in-memory.
    private struct IdleScheduleSnapshot {
        /// Today's row on the unified Schedule across all goals.
        let today: ScheduleDay?
        /// Pending items planned for today across all Schedules.
        let pendingToday: [SchedulePlanItem]
        /// Deliberate placements still live: planned for any future day, or
        /// overdue by less than `idleSuggestionRecency`. Automatic activity
        /// anchors never appear here — `scheduledSources` carries them, but
        /// they are history, not a plan.
        let livePlacements: [ScheduledSourceEntry]

        init(
            today: ScheduleDay?,
            livePlacements: [ScheduledSourceEntry],
            isSourceVisible: (String) -> Bool = { _ in true }
        ) {
            self.today = today
            self.pendingToday = today?.items.filter { !$0.isCompleted && isSourceVisible($0.sourceID) } ?? []
            self.livePlacements = livePlacements
        }
    }

    private var idleScheduleSnapshot: IdleScheduleSnapshot {
        // Screen record mode: only the recording Notebook's sources and safe
        // public captures from the take are planned on screen.
        let isSourceVisible: (String) -> Bool = { vm.isSourceIDVisibleInRecordingMode($0) }
        let earliest = Date().addingTimeInterval(-Self.idleSuggestionRecency)
        return IdleScheduleSnapshot(
            today: vm.unifiedScheduleDays(containing: Date()).first(where: \.isToday),
            livePlacements: vm.scheduledSources.filter { entry in
                !entry.isAutomatic
                    && !entry.placement.isCompleted
                    && entry.placement.plannedAt >= earliest
                    && isSourceVisible(entry.placement.sourceID)
            },
            isSourceVisible: isSourceVisible
        )
    }

    /// Day-scoped, so hiding today's plan clears today only — tomorrow's plan
    /// still gets to introduce itself.
    private var idleTodayScheduleDismissalKey: String {
        "today-schedule:\(IdleSuggestionDismissals.dayScope())"
    }

    /// Today's plan in its row's popover: every pending planned item, each
    /// row opening its source and its leading circle checking it off — the
    /// one completion by hand (schedule-design.md) — and Quiz me on these
    /// under them, which starts a review of the whole day. Planning itself
    /// happens in the conversation. This was the Today card under the
    /// greeting until 2026-10-06, when the welcome kept only its greeting
    /// and a few suggestions (the product owner: "cleaner and fewer buttons and bells
    /// and whistles"); the plan moved behind its row rather than leaving.
    private struct IdleTodayPlanList: View {
        let plan: IdleTodayPlan
        let close: () -> Void

        /// Taller than this, the list scrolls.
        private static let rowsBeforeScrolling = 8

        private var rows: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.items) { item in
                    IdleScheduleItemRow(
                        item: item,
                        action: {
                            close()
                            plan.start(item)
                        },
                        onMarkDone: { plan.markDone(item) }
                    )
                }
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if plan.items.count > Self.rowsBeforeScrolling {
                    ScrollView { rows }
                        .frame(height: 300)
                } else {
                    rows
                }

                // The day's primary action under the list it acts on.
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.top, 2)
                Button {
                    close()
                    plan.quiz()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .foregroundStyle(.primary)
                            .frame(width: 20)
                        Text(plan.items.count == 1 ? "Quiz me on this source" : "Quiz me on these")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Start a review of today's sources")
            }
            .padding(.vertical, 10)
            .frame(width: 340, alignment: .leading)
        }
    }

    /// One pending planned item in today's plan. Clicking the row starts
    /// the item: source into context, opened in the reader, chat kept alongside.
    /// The leading circle is the only way this list ever gets checked off by
    /// hand — opening a source records history, never completion — so it is a
    /// real control rather than a bullet, and a sibling of the open button
    /// rather than nested inside it (a Button inside another Button's label
    /// swallows clicks on macOS).
    private struct IdleScheduleItemRow: View {
        let item: SchedulePlanItem
        let action: () -> Void
        let onMarkDone: () -> Void
        @State private var isHovered = false
        @State private var isCheckHovered = false

        /// What the app has actually seen happen with this source today. Never
        /// a completion claim — that is what the check is for.
        private var activityHint: String? {
            if item.activityKinds.contains(.review) { return "reviewed" }
            if item.activityKinds.contains(.chat) { return "discussed" }
            if item.activityKinds.contains(.listening) { return "played" }
            if item.activityKinds.contains(.watching) { return "played" }
            if item.activityKinds.contains(.reading) { return "opened" }
            return nil
        }

        var body: some View {
            HStack(spacing: 0) {
                Button(action: onMarkDone) {
                    Image(systemName: isCheckHovered ? "checkmark.circle" : "circle")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(isCheckHovered ? Color.primary : Color.secondary.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: 0))
                .onHover { isCheckHovered = $0 }
                .padding(.leading, 8)
                .help("Mark as done")
                .accessibilityLabel("Mark done: \(item.title)")

                Button(action: action) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let activityHint {
                            Text(activityHint)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .zoomedSystemFont(size: 8, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.isMissingSource)
                .opensInOtherWindow(sourceID: item.isMissingSource ? nil : item.sourceID)
                .help("Open this source")
            }
            .background(Color.primary.opacity(isHovered ? 0.05 : 0))
            .onHover { isHovered = $0 }
        }
    }

    /// The Notebook a fresh chat should suggest reviewing: the active Notebook
    /// when it has approved sources, otherwise any Notebook that does.
    private var idleSuggestedReviewNotebook: LearningGoalRecord? {
        let candidates = vm.notebooks.filter { !$0.approvedSourceIDs.isEmpty }
        if let activeID = vm.activeNotebookId,
           let active = candidates.first(where: { $0.id == activeID }) {
            return active
        }
        return candidates.first
    }

    /// How stale a suggestion may be before it stops being a suggestion. A plan
    /// abandoned two months ago is not the next thing to do, and offering it
    /// as one is how this screen came to advertise work nobody meant to resume.
    private static let idleSuggestionRecency: TimeInterval = 14 * 24 * 60 * 60

    /// The most overdue still-live placement, resolved through the day model so
    /// the row can start it exactly like today's plan does. Used when today is
    /// clear but the plan has recent work left elsewhere.
    private func idleNextScheduledItem(
        in livePlacements: [ScheduledSourceEntry]
    ) -> (item: SchedulePlanItem, goalTitle: String?)? {
        guard let next = livePlacements
            .min(by: { $0.placement.plannedAt < $1.placement.plannedAt }) else { return nil }
        // The day model drops placements whose source was archived or deleted,
        // so a resolved item is also proof the source is still openable.
        guard let item = vm.unifiedScheduleDays(containing: next.placement.plannedAt)
            .flatMap(\.items)
            .first(where: { $0.id == next.id }) else { return nil }
        return (item, item.goalTags.first?.title)
    }

    private static func readNextDismissalKey(_ pick: ReadNextSuggestion) -> String {
        "read-next:\(pick.sourceID)"
    }

    /// How many picks to hold, so hiding one has a next to fall back on.
    private static let readNextPickCount = 5

    /// Kinds of source a learner reads, watches or listens to on their own
    /// time. Meetings, course handouts and posts are left out: a meeting was
    /// attended, not queued, and a post is too slight to be the next thing.
    private static let readNextSourceTypes: Set<StudioSourceType> = [.article, .paper, .book, .podcast, .video, .manual]

    /// Its own storage actor and connection. The first ranking of a session
    /// loads every chunk vector into the shared index, which takes seconds on
    /// a large library; on the view model's storage lane that load would sit
    /// in front of the next chat send.
    private static let readNextStorage = StorageService()

    /// Finds the "Read next" picks for the empty chat. The pool is gathered
    /// here from what the active library already holds in memory; the ranking
    /// (`StorageService.readNextSuggestions`) reads the database and the
    /// vector index on `readNextStorage`, at utility priority.
    private func refreshReadNextSuggestions() async {
        guard vm.hasCompletedInitialQueueLoad else { return }
        let planned = Set(vm.scheduledSources.lazy.filter { !$0.placement.isCompleted }.map(\.placement.sourceID))
        let candidates = Set(vm.articles.lazy.filter { article in
            article.state == .ready
                && article.status == .active
                && !article.isHidden
                && Self.readNextSourceTypes.contains(article.sourceType)
                && !planned.contains(article.id)
                && vm.isSourceIDVisibleInRecordingMode(article.id)
        }.map(\.id))
        let storage = Self.readNextStorage
        let limit = Self.readNextPickCount
        let result = await Task(priority: .utility) {
            try await storage.readNextSuggestions(candidateIDs: candidates, limit: limit)
        }.result
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let picks):
            readNextSuggestions = picks
        case .failure(let error):
            vm.logger.error("Read next suggestions failed: \(error.localizedDescription, privacy: .public)")
            readNextSuggestions = []
        }
    }

    /// Sending this opens the Learning goal workflow in the tutor prompt:
    /// confirm topic and deadline, create the Notebook and Goal, discover and
    /// approve sources, then pace them onto the Schedule.
    private static let setGoalPrompt = "I want to set a learning goal. Help me settle on the topic and deadline, find sources for it in my library, and plan a schedule."

    /// Every suggestion the current state supports, most useful first, before
    /// the learner's dismissals are applied. `idleWelcomeState` filters this
    /// down to what renders — keeping both lets the empty state tell "nothing
    /// to suggest" apart from "everything suggested has been hidden".
    private func allIdleSuggestions(_ schedule: IdleScheduleSnapshot) -> [IdleSuggestion] {
        var suggestions: [IdleSuggestion] = []

        // Today's plan leads, as its card stood over everything else until
        // 2026-10-06; its row opens the plan (`IdleTodayPlanList`).
        if !schedule.pendingToday.isEmpty {
            let items = schedule.pendingToday
            suggestions.append(IdleSuggestion(
                id: "today-plan",
                systemImage: "checklist",
                title: idleTodayPlanTitle(schedule),
                dismissalKey: idleTodayScheduleDismissalKey,
                action: {},
                help: "Today's plan: open a source, check one off, or quiz yourself on them",
                todayPlan: IdleTodayPlan(
                    items: items,
                    start: { item in Task { await vm.startScheduleItem(item) } },
                    markDone: { item in Task { await vm.markScheduleSourceDone(sourceID: item.sourceID) } },
                    quiz: { Task { await startTodayReviewFromIdle(items) } }
                )
            ))
        }

        if let plan = vm.memoryCompanionPlan, !plan.isEmpty {
            suggestions.append(IdleSuggestion(
                id: "memory-check",
                systemImage: "brain.head.profile",
                title: "Memory check · \(MemoryReviewBudget.clamp(memoryBudgetMinutes)) min",
                dismissalKey: "memory-check:\(StudioViewModel.dailyReviewPlanCacheDay())",
                action: { await startMemoryCompanionFromIdle(plan) }
            ))
        }

        // When today has pending sources, the quiz action lives in today's
        // plan (IdleTodayPlanList's footer), right under the list it acts on —
        // so it isn't repeated as a suggestion row here. The continue/review
        // fallbacks are only for when today is already clear.
        if schedule.pendingToday.isEmpty {
            if let next = idleNextScheduledItem(in: schedule.livePlacements) {
                // Nothing left for today, but the Schedule still has work —
                // point at it rather than falling back to a generic review.
                let title = next.goalTitle.map { "Continue \u{201C}\($0)\u{201D}" } ?? "Continue your schedule"
                suggestions.append(IdleSuggestion(
                    id: "continue-schedule",
                    systemImage: "arrow.forward.circle",
                    title: title,
                    dismissalKey: "continue-schedule:\(next.item.id)",
                    action: { await vm.startScheduleItem(next.item) }
                ))
            } else if let notebook = idleSuggestedReviewNotebook {
                suggestions.append(IdleSuggestion(
                    id: "notebook-review",
                    systemImage: "graduationcap",
                    title: "Review \u{201C}\(notebook.title)\u{201D}",
                    dismissalKey: "notebook-review:\(notebook.id)",
                    action: { await startNotebookReviewFromIdle(notebook) }
                ))
            }
        }

        // Planning the day is the one thing worth doing in any empty chat, so it
        // is always on offer. By the afternoon it plans tomorrow, the same turn
        // `/plan` takes, and hiding it hides it for the rest of the day only.
        let plansTomorrow = Calendar.current.component(.hour, from: Date()) >= DayPlan.planTomorrowFromHour
        suggestions.append(IdleSuggestion(
            id: "plan-day",
            systemImage: "calendar.day.timeline.left",
            title: plansTomorrow ? "Plan tomorrow" : "Plan my day",
            dismissalKey: "plan-day:\(DayPlan.dateString(for: Date()))",
            action: { await startPlanDayFromIdle() }
        ))

        // Only a chat from the last two weeks is something to "resume". The
        // list is newest-first, so an old first entry means there is nothing
        // recent — not that this one deserves promoting.
        if let session = vm.filteredReviewSessionLinks().first(where: \.isLocalMCPSession),
           session.createdAt >= Date().addingTimeInterval(-Self.idleSuggestionRecency) {
            let sessionTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionTitle.isEmpty {
                suggestions.append(IdleSuggestion(
                    id: "resume-session",
                    systemImage: "clock.arrow.circlepath",
                    title: "Resume \u{201C}\(sessionTitle)\u{201D}",
                    dismissalKey: "resume-session:\(session.id)",
                    action: { await openPickedSession(session) },
                    otherWindowDestination: session.isLocalMCPSession ? .chat(session.id) : nil
                ))
            }
        }

        // The first pick not already hidden, so declining one surfaces the
        // next. When every pick is hidden the first one stands for them, which
        // keeps "everything hidden" true for the restore link.
        let readNextPicks = readNextSuggestions.filter { vm.articlesById[$0.sourceID] != nil }
        if let pick = readNextPicks.first(where: { !IdleSuggestionDismissals.shared.isDismissed(Self.readNextDismissalKey($0)) })
            ?? readNextPicks.first,
           let article = vm.articlesById[pick.sourceID] {
            let verb: String
            switch article.sourceType {
            case .podcast: verb = "Listen to"
            case .video: verb = "Watch"
            default: verb = "Read"
            }
            let nearestTitle = vm.articlesById[pick.nearestReadSourceID]?.title
            suggestions.append(IdleSuggestion(
                id: "read-next",
                systemImage: "books.vertical",
                title: "\(verb) \u{201C}\(article.title)\u{201D}",
                dismissalKey: Self.readNextDismissalKey(pick),
                action: { await vm.openSourceInReader(pick.sourceID) },
                help: nearestTitle.map { "Close to \u{201C}\($0)\u{201D}, from your recent reading" }
            ))
        }

        // `selectedArticle` outlives the reader that showed it, so this asked
        // about a source that had not been on screen for days. Offer it only
        // while a Reader in this chat's own window shows it — the key
        // window's tabs and the app-wide Reader flag said nothing about this
        // one — and not for a source the learner left out of the chat.
        let leftOut = manager.onScreenSourcesLeftOut
        if let shown = sourcesOnScreenBesideChat.first(where: { !leftOut.contains($0.id) }),
           let article = vm.articlesById[shown.id] {
            suggestions.append(IdleSuggestion(
                id: "explain-reading",
                systemImage: "text.book.closed",
                title: "Explain what I'm reading",
                dismissalKey: "explain-reading:\(article.id)",
                action: { explainCurrentReading(article) }
            ))
        }

        // With nothing planned there is nothing to continue, so offer the way in:
        // the chat workflow that settles the goal and lays out the Schedule. It
        // sorts last, becoming the primary row only when it is the sole one.
        // Waits for the first library load: before it, "nothing planned" is
        // just "not read yet", and this row would flash at a learner whose
        // schedule is seconds away.
        if schedule.livePlacements.isEmpty, vm.hasCompletedInitialQueueLoad {
            suggestions.append(IdleSuggestion(
                id: "set-goal",
                systemImage: "target",
                title: "Set a learning goal",
                // No instance to scope to, so this one stays hidden until the
                // learner asks for it back with the restore link.
                dismissalKey: "set-goal",
                action: { await startGoalSetupFromIdle() }
            ))
        }

        return suggestions
    }

    /// What the idle state actually shows, after dismissals.
    private struct IdleWelcomeState {
        /// The first `idleSuggestionLimit` not hidden.
        let suggestions: [IdleSuggestion]
        /// Everything on offer has been hidden, so the restore link is the way
        /// back — the reason a dismissal is never a dead end.
        let showsRestore: Bool

        var hasContent: Bool { !suggestions.isEmpty || showsRestore }
    }

    /// Resolved in one pass: the plan lookup and the suggestion list are each
    /// walked once per render rather than once per question asked about them.
    private func idleWelcomeState(_ schedule: IdleScheduleSnapshot) -> IdleWelcomeState {
        let dismissals = IdleSuggestionDismissals.shared
        let all = allIdleSuggestions(schedule)
        let visible = all.filter { !dismissals.isDismissed($0.dismissalKey) }
        return IdleWelcomeState(
            suggestions: Array(visible.prefix(Self.idleSuggestionLimit)),
            showsRestore: !all.isEmpty && visible.isEmpty
        )
    }

    /// Hands the learner to the tutor's Learning goal workflow: it asks for the
    /// topic and deadline, then creates the Notebook/Goal, discovers sources, and
    /// paces them onto the Schedule through the same tools the Notebooks panel uses.
    @MainActor
    private func startGoalSetupFromIdle() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(Self.setGoalPrompt)
    }

    /// Sends what `/plan` sends: the chat that plans the day into the Mac's
    /// Calendar, where the Now chip shows it filling in.
    @MainActor
    private func startPlanDayFromIdle() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(ReviewSlashCommandParser.planDayRequest(nil))
    }

    @MainActor
    private func startTodayReviewFromIdle(_ items: [SchedulePlanItem]) async {
        let todayArticles = articles(for: items)
        guard !todayArticles.isEmpty else { return }
        await startVoiceReview(with: todayArticles, topic: "Today's review")
    }

    @MainActor
    private func startMemoryCompanionFromIdle(_ plan: MemoryCompanionPlan) async {
        guard !plan.isEmpty, !manager.isSearching, !manager.isGenerating else { return }
        await vm.refreshMemoryCompanionPlan(surfaceErrors: true)
        guard let plan = vm.memoryCompanionPlan, !plan.isEmpty else {
            vm.showToast("Nothing is due for a memory check right now.")
            return
        }
        vm.startCompanionReview(
            goalID: plan.goalID,
            sourceIDs: plan.sourceIDs,
            topic: plan.topic,
            rationale: "Prioritize durable retrieval: revisit unresolved struggles first, then due memories, then newly consumed material that has not yet been recalled.",
            memoryPlan: plan
        )
    }

    @MainActor
    private func startNotebookReviewFromIdle(_ notebook: LearningGoalRecord) async {
        // What the notebook's chats read: its own sources and those of the
        // context notebooks put in, as a review started from outside the
        // panel reads them (`requestNotebookReview`).
        let readable = vm.notebookChatPool(notebook)
            .compactMap { vm.articlesById[$0] }
            .filter { vm.isSourceIncludedInKnowledge($0) }
        let unticked = vm.notebookChatExclusions[notebook.id] ?? []
        let notebookArticles = readable.filter { !unticked.contains($0.id) }
        guard !notebookArticles.isEmpty else {
            if !readable.isEmpty {
                vm.showToast("Tick a source in \u{201C}\(notebook.title)\u{201D} to review it.")
            }
            return
        }
        guard !manager.isSearching, !manager.isGenerating else { return }
        linkedResearchNotebookID = notebook.id
        readsNotebookTicksLive = false
        vm.setContextSources(notebookArticles.map(\.id))
        clearComposer()
        pendingReaderSelection = nil
        guard await syncSynthesisToolContext() else { return }
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(
            topic: notebook.title,
            articles: notebookArticles,
            goalID: notebook.id,
            notebookScopeID: notebook.id
        )
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    @MainActor
    private func explainCurrentReading(_ article: StudioArticle) {
        adoptLiveNotebookSelection()
        vm.addSourceToContext(article.id)
        draft = "Explain the key ideas of \u{201C}\(article.title)\u{201D}."
        lastInsertedDefaultPrompt = draft
        requestComposerFocus()
    }

    /// Title of the currently selected chat, shown as a header above the transcript.
    /// Prefers the saved session record so renames made in the rail update live;
    /// falls back to the manager's topic for sessions not yet in the saved list.
    private var selectedChatTitle: String? {
        guard let sessionID = manager.currentSessionID else { return nil }
        // While the title is just the opening message echoed back (pending the
        // AI-suggested title), don't duplicate the first bubble — show a
        // placeholder. A manual rename diverges from the echoed topic and wins.
        return ChatHeaderTitle.title(
            sessionTitle: vm.reviewSessionLinks.first { $0.id == sessionID }?.title,
            topic: manager.topic,
            isProvisional: manager.titleIsProvisional
        )
    }

    @ViewBuilder
    private var chatTitleHeader: some View {
        if let title = selectedChatTitle {
            let docked = usesDockedHeaderChrome
            let band = docked ? titlebarBandHeight : nil
            chatTitleLabel(title)
            // A title long enough to fill the column would otherwise run under
            // the header's ⋯, which no longer travels with the column's edge.
            // Truncate it a control-gap short of the button, and give up
            // nothing at all when the column already ends left of that.
                .padding(.trailing, chatHeaderTitleClearance)
            // Match the transcript's readable column: the title begins
            // on the same leading outline instead of floating at panel center.
                .frame(maxWidth: chatColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, chatHeaderGutter)
            // Keep the row as tall as the control the overlay adds, so the
            // button never spills past the header's own bounds.
                .frame(minHeight: chatHeaderControlSize)
            // The ⋯ belongs with the pane's other controls rather than on the
            // reading column's invisible trailing edge. That column is
            // centered and, in a split, capped well short of the pane, which
            // left a control stranded mid-header on a wide pane. Anchored here
            // it lands one control gap in from the pin instead. Quiet chrome
            // (docs/ui-design.md, 2026-10-06): the title, a review's way out
            // while it has the window, the ⋯ and the pane's ×; Copy
            // conversation and the notebook's Chats are the ⋯'s.
                .overlay(alignment: .trailing) {
                    HStack(spacing: StudioPaneClosePlacement.interControlSpacing) {
                        memoryReviewFocusChrome
                        chatActionsMenu
                    }
                    .padding(.trailing, chatHeaderControlTrailingInset)
                }
                .padding(.top, docked ? 0 : 10)
                .padding(.bottom, docked ? 0 : 9)
                .frame(height: band ?? (docked ? StudioPanelChrome.headerHeight : nil))
                // The titlebar version is fixed while the transcript scrolls.
                // Give it an opaque backdrop so messages never show through
                // the title row when the outer panel clip exposes the band.
                .background(docked ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                .help(title)
                .overlay(alignment: .bottom) {
                    if !docked {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                    }
                }
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The title, or the field renaming it. A click on the title renames the
    /// chat, as Codex's does (product owner, 2026-10-13: "at first it should be a
    /// copy of the codex ... functionality"); Return keeps the new name and
    /// Escape the old. A chat with no row yet, a day's review and a team's
    /// snapshot keep a plain title, selectable to paste elsewhere.
    @ViewBuilder
    private func chatTitleLabel(_ title: String) -> some View {
        if isRenamingChatTitle {
            TextField("Add a title…", text: $chatTitleDraft)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .focused($chatTitleFieldFocused)
                .onSubmit { commitChatTitleRename() }
                .onExitCommand { isRenamingChatTitle = false }
                .onChange(of: chatTitleFieldFocused) { _, focused in
                    if !focused { commitChatTitleRename() }
                }
                .onChange(of: manager.currentSessionID) { _, _ in isRenamingChatTitle = false }
                .accessibilityLabel("Chat title")
        } else if canRenameChat {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.disabled)
                .contentShape(Rectangle())
                .onTapGesture { beginChatTitleRename() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Renames the chat")
        } else {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            // A quiz or chat title is worth pasting elsewhere; the titlebar
            // band's WindowDragBlocker keeps a drag here a text selection.
                .textSelection(.enabled)
        }
    }

    /// The chat's saved row, which a rename, a pin and a hide act on; nil
    /// before the chat is saved.
    private var openChatRecord: ReviewSessionRecord? {
        guard let sessionID = manager.currentSessionID else { return nil }
        return vm.reviewSessionLinks.first { $0.id == sessionID }
    }

    /// Whether the open chat is the learner's to rename here: saved, not a
    /// day's review (Memory names it), not a team's snapshot.
    private var canRenameChat: Bool {
        guard let record = openChatRecord else { return false }
        return !MemoryReviewSession.isMemorySession(record.id) && !record.isTeamSnapshot
    }

    private func beginChatTitleRename() {
        guard let record = openChatRecord, canRenameChat else { return }
        chatTitleDraft = record.title
        isRenamingChatTitle = true
        chatTitleFieldFocused = true
    }

    private func commitChatTitleRename() {
        guard isRenamingChatTitle else { return }
        isRenamingChatTitle = false
        let title = chatTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = openChatRecord, !title.isEmpty, title != record.title else { return }
        Task { await vm.renameReviewSession(record.id, title: title) }
    }

    /// Whether this panel is the review the window has given itself over to.
    private var showsMemoryReviewFocusChrome: Bool {
        guard let sessionID = manager.currentSessionID else { return false }
        return vm.memoryReviewFocusSessionID == sessionID
    }

    /// What a review in focus puts in the header: the way out
    /// (`MemoryReviewFocusChrome`, shared with the card review). While the
    /// goal is unmet the × ends today's session, and says so first.
    @ViewBuilder
    private var memoryReviewFocusChrome: some View {
        if showsMemoryReviewFocusChrome {
            MemoryReviewFocusChrome(
                onTitlebarBand: usesTitlebarBandHeader,
                controlSize: chatHeaderControlSize,
                leavingEnds: MemoryReviewCommitment.leavingEndsSession(goalTracker.state)
            ) {
                vm.leaveMemoryReviewFocus(sessionID: manager.currentSessionID)
            }
        }
    }

    /// The notebook whose chats the header's ⋯ lists: the window's, in its
    /// primary chat (a second chat beside it opens its own picks in place).
    private var headerNotebookID: String? {
        guard usesDockedHeaderChrome, acceptsGlobalNavigationRequests else { return nil }
        return windowState?.NotebookID
    }

    /// Width the header's trailing controls take, so the title truncates clear
    /// of them however many there are.
    private var chatHeaderControlsWidth: CGFloat {
        // The ⋯, once there is something under it.
        var width: CGFloat = showsChatActionsMenu ? chatHeaderControlSize : 0
        guard showsMemoryReviewFocusChrome else { return width }
        // The review's × in front of it.
        if width > 0 { width += StudioPaneClosePlacement.interControlSpacing }
        return width + chatHeaderControlSize
    }

    /// The chat this header's ⋯ acts on: a chat that has a row to be opened
    /// elsewhere or addressed. A new chat with nothing in it has none.
    private var chatActionsSessionID: String? { manager.currentSessionID }

    /// The ⋯ is drawn once it holds something: this chat's actions, or, in a
    /// notebook window, the notebook's chats.
    private var showsChatActionsMenu: Bool {
        chatActionsSessionID != nil || headerNotebookID != nil
    }

    /// The header's ⋯: the notebook's chats, where this chat can go — the
    /// pane beside it, another window — its address and its transcript. The
    /// sidebar's row has carried these all along, but the chat in front of
    /// the learner had no menu at all (product owner, 2026-09-21: "I also don't have
    /// a, you know, three dots where I can be like, move to the other
    /// window"). Since 2026-10-06 (Quiet chrome, docs/ui-design.md) it also
    /// holds what stood beside it on the line: **Chats in This Notebook** ▸
    /// (`NotebookChatsMenuItems`, also the notebook rail's Chats menu) and
    /// **Copy Conversation**.
    ///
    /// Docked, this header hangs in the titlebar band, where a SwiftUI `Menu`
    /// label never lights up and its press can be taken by the window drag —
    /// the same reason the Reader's overflow is a `TitlebarBandButton` opening
    /// an `NSHostingMenu`. The items are authored once in SwiftUI below and
    /// built fresh per press; the band path re-injects the view model and the
    /// window, which a hosting menu does not inherit.
    @ViewBuilder
    private var chatActionsMenu: some View {
        if showsChatActionsMenu {
            if usesTitlebarBandHeader, #available(macOS 14.4, *) {
                TitlebarBandButton(
                    help: "More chat actions",
                    accessibilityLabel: "More chat actions",
                    accessibilityIdentifier: "mac.chatActions",
                    controlSize: chatHeaderControlSize,
                    action: {},
                    menu: {
                        NSHostingMenu(rootView: chatActionsMenuItems(sessionID: chatActionsSessionID)
                            .environment(vm)
                            .environment(windowState))
                    }
                ) {
                    chatActionsMenuLabel
                }
            } else {
                Menu {
                    chatActionsMenuItems(sessionID: chatActionsSessionID)
                } label: {
                    chatActionsMenuLabel
                        .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight(cornerRadius: chatHeaderControlSize / 2, inset: -5, opacity: 0.12)
                .help("More chat actions")
                .accessibilityLabel("More chat actions")
                .accessibilityIdentifier("mac.chatActions")
            }
        }
    }

    private var chatActionsMenuLabel: some View {
        Image(systemName: "ellipsis")
            .zoomedSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chatActionsMenuItems(sessionID: String?) -> some View {
        // A notebook window's chats, which the rail's icon strip lists too
        // (and no longer under the notebook's folder).
        if let notebookID = headerNotebookID, windowState != nil {
            Menu("Chats in This Notebook", systemImage: "bubble.left.and.bubble.right") {
                NotebookChatsMenuItems(notebookID: notebookID, currentSessionID: manager.currentSessionID)
            }
            if sessionID != nil { Divider() }
        }
        if let sessionID {
            chatActionsSessionItems(sessionID: sessionID)
        }
    }

    @ViewBuilder
    private func chatActionsSessionItems(sessionID: String) -> some View {
        // Codex's header menu leads with the chat's own marks: Pin, Rename,
        // and Hide in place of its Archive, as the sidebar row's menu does.
        if let record = openChatRecord, record.id == sessionID, !MemoryReviewSession.isMemorySession(sessionID) {
            let isPinned = vm.isChatPinned(sessionID)
            Button {
                vm.setChatPinned(sessionID, pinned: !isPinned)
            } label: {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
            if canRenameChat {
                Button {
                    beginChatTitleRename()
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            Button {
                Task { await vm.setReviewSessionHidden(sessionID, hidden: !record.isHidden) }
            } label: {
                Label(record.isHidden ? "Show" : "Hide", systemImage: record.isHidden ? "eye" : "eye.slash")
            }
            Divider()
        }
        OpenStudioDestinationInOtherWindowMenu(
            destination: .chat(sessionID),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        Divider()
        // The chat's address, `foreverlm://chat/<id>`: the same item the
        // sidebar row carries, so a chat being read here can be handed to a
        // person or to an assistant on the plugin without going looking for
        // its row.
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                StudioEntityLink.chat(sessionID).markdownDestination,
                forType: .string
            )
            vm.showToast("Link copied")
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        // The whole transcript, named for what it does (product owner, 2026-09-22,
        // asking for a copy-the-whole-chat button that was already there,
        // wearing each answer's own copy glyph on the header). The header's
        // button went on 2026-10-06 (Quiet chrome): this is the one place.
        Button {
            copyConversation()
        } label: {
            Label("Copy Conversation", systemImage: "doc.on.doc")
        }
        .disabled(manager.chatMessages.isEmpty)
        // Turning an exploring chat into a notebook (product owner, 2026-10-03).
        if !MemoryReviewSession.isMemorySession(sessionID), teamSnapshotRecord == nil,
           !vm.isActiveLibraryReadOnly, manager.chatMessageCount > 0 {
            Divider()
            Button {
                requestNotebookFromChat(sessionID)
            } label: {
                Label("New Notebook from This Chat", systemImage: "rectangle.stack.badge.plus")
            }
        }
        // A memory review is dealt as cards; the conversation under them is
        // one press away, and back.
        if MemoryReviewSession.isMemorySession(sessionID) {
            Divider()
            let showsCards = memoryReviewLayout == .cards
            Button {
                memoryReviewCardIndex = nil
                memoryReviewLayoutRaw = (showsCards ? MemoryReviewLayout.conversation : .cards).rawValue
            } label: {
                Label(
                    showsCards ? "Show as Conversation" : "Show as Cards",
                    systemImage: showsCards ? "text.bubble" : "rectangle.stack"
                )
            }
        }
        // The page passages this chat was opened on (`docOriginMenuTitle`),
        // here since 2026-10-06 rather than over the composer.
        if !sessionDocLinks.isEmpty {
            Divider()
            ForEach(sessionDocLinks) { entry in
                Button {
                    vm.revealArtifact(entry.link.artifactID)
                } label: {
                    Label(docOriginMenuTitle(for: entry), systemImage: "arrow.up.left.square")
                }
            }
        }
        // The context ring's breakdown of the context and this chat's cost.
        // The composer draws the ring only once the context is filling up
        // (2026-10-06); this opens the breakdown before that.
        if manager.contextBreakdown != nil {
            Divider()
            Button {
                isContextBreakdownRequested = true
            } label: {
                Label("Context and Cost…", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
    }

    private var memoryReviewLayout: MemoryReviewLayout {
        MemoryReviewLayout(rawValue: memoryReviewLayoutRaw) ?? .cards
    }

    /// The text column of a memory review card, head and exchange alike.
    private var memoryReviewCardTextWidth: CGFloat {
        MemoryReviewCardSurface.textColumnWidth(
            columnMaxWidth: chatColumnMaxWidth,
            gutter: chatHeaderGutter,
            zoom: uiZoomScale
        )
    }

    /// Whether this pane draws its memory review as a deck of cards. A walk
    /// playing in the same chat keeps its own deck.
    private var showsMemoryReviewCards: Bool {
        isMemoryReviewChat && memoryReviewLayout == .cards && manager.walkthroughPlayback == nil
    }

    /// What the deck deals a card each: today's topics (docs/memory-design.md,
    /// "Review by topic"), or, in a review planned source by source, today's
    /// sources and chats in plan order. Both are drawn as the same card.
    private var memoryReviewCardSubjects: [MemoryReviewCardSubject] {
        if manager.isTopicMemoryReview {
            return manager.memoryReviewTopics.map(MemoryReviewCardSubject.init(topic:))
        }
        guard manager.isMemoryReviewSession else { return [] }
        return memoryReviewStripEntries.map { entry in
            MemoryReviewCardSubject(
                sourceID: entry.id,
                title: entry.title,
                ideaIDs: manager.memoryReviewIdeaIDs(forSource: entry.id)
            )
        }
    }

    /// A card carries its own answer field, so the pane's composer steps
    /// aside while the deck is up. It comes back for a side question, which
    /// is typed with the composer's token, and in the conversation layout.
    private var hidesComposerForMemoryCard: Bool {
        showsMemoryReviewCards && !isSideQuestionMode
    }

    /// Gutter the chat header keeps outside its reading column.
    private let chatHeaderGutter: CGFloat = 14

    /// Hit target of the header's own trailing control.
    private let chatHeaderControlSize: CGFloat = 28

    /// Where the header's ⋯ stops, measured in from the panel's trailing
    /// edge.
    private var chatHeaderControlTrailingInset: CGFloat {
        StudioChatHeaderClearance.controlTrailingInset(
            gutter: chatHeaderGutter,
            chromeClearance: headerTrailingChromeClearance
        )
    }

    /// Trailing padding the title gives up so it truncates before reaching the
    /// header's ⋯. Zero whenever the reading column ends left of it anyway,
    /// which is the common case on a pane wider than the column.
    private var chatHeaderTitleClearance: CGFloat {
        StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: chatPanelWidth,
            gutter: chatHeaderGutter,
            columnMaxWidth: chatColumnMaxWidth,
            chromeClearance: StudioChatHeaderClearance.titleClearance(
                gutter: chatHeaderGutter,
                chromeClearance: headerTrailingChromeClearance,
                controlSize: chatHeaderControlsWidth
            )
        )
    }

    @MainActor
    private func copyConversation() {
        let transcript = ReviewSessionManager.copiedConversationText(from: manager.chatMessages)
        guard !transcript.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        vm.showToast("Conversation copied")
    }

    /// Whether the transcript takes the height it is given rather than its own:
    /// a fixed host does, and so does the page's side chat card, whose
    /// transcript region has a height of its own (`PageSideChatLayout`).
    private var fillsTranscriptHost: Bool { fillsAvailableSpace || pageSideChat != nil }

    private var compactTranscriptPanel: some View {
        VStack(spacing: 0) {
            // The side chat's card draws its own header above this.
            if !usesTitlebarBandHeader, pageSideChat == nil {
                chatTitleHeader
            }
            memoryReviewSourceStrip
            walkthroughPlaybackStrip
            walkthroughCardDeck
            // Kept, not removed, while the card owns the pane, so its scroll
            // position and its handlers survive the first question. A memory
            // review drawn as cards puts the transcript on a card of its own.
            VStack(spacing: 0) {
                if showsMemoryReviewCards {
                    MemoryReviewCardHeader(
                        manager: manager,
                        selectedIndex: memoryReviewCardIndex,
                        textColumnWidth: memoryReviewCardTextWidth,
                        subjects: memoryReviewCardSubjects,
                        sourceTitle: { id in
                            vm.articlesById[id]?.title ?? manager.memoryReviewMaterialTitles[id]
                        }
                    )
                }
                transcriptScrollView
                    // A card's exchange is set larger than the chat
                    // (`MemoryReviewCardSurface.textScale`); its head and
                    // foot keep the chat's size.
                    .environment(
                        \.uiZoomScale,
                        showsMemoryReviewCards ? uiZoomScale * MemoryReviewCardSurface.textScale : uiZoomScale
                    )
                if showsMemoryReviewCards {
                    // The session bar draws the day as segments; the foot
                    // keeps Back and Next.
                    MemoryReviewCardFooter(
                        manager: manager,
                        selectedIndex: $memoryReviewCardIndex,
                        showsSegments: false
                    )
                }
            }
            .modifier(MemoryReviewCardSurface(
                isOn: showsMemoryReviewCards,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter
            ))
            .frame(height: walkthroughFillsPane ? 0 : nil)
            .opacity(walkthroughFillsPane ? 0 : 1)
            .allowsHitTesting(!walkthroughFillsPane)
            .accessibilityHidden(walkthroughFillsPane)
        }
        .animation(.easeInOut(duration: 0.25), value: walkthroughFillsPane)
        // In a fixed host the bottom-aligned layout puts any leftover height
        // *above* the transcript, so a fixed height estimated from the panel
        // size leaves a gap over the chat title. Fill the height instead so
        // the title pins to the top and the composer stays at the bottom.
        .frame(height: fillsTranscriptHost ? nil : transcriptHeight)
        .frame(maxHeight: fillsTranscriptHost ? .infinity : nil)
        .modifier(TranscriptSurface(flat: fillsTranscriptHost))
        // Measured outside the frame, so the card's own height never feeds
        // back into the share it may take.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            transcriptPanelHeight = height
        }
        .onChange(of: manager.walkthroughPlayback?.sourceID, initial: true) { _, _ in
            registerWalkthroughDeck()
        }
        .overlay(alignment: .top) {
            if usesTitlebarBandHeader, let band = titlebarBandHeight {
                // On the band's chrome (`StudioBandRow`), so the transcript
                // and its surface never show there.
                StudioBandRow(band: band) {
                    chatTitleHeader
                        .background(WindowDragBlocker())
                }
            }
        }
    }


    /// The day's review, as material rather than as a transcript: the sources
    /// today covers, each checked off once its contour has been graded.
    ///
    /// Only a graded contour checks a source off. Being asked about it, or
    /// opening it, is activity — the same line the Schedule draws between what
    /// happened and what was finished.
    @ViewBuilder
    private var memoryReviewSourceStrip: some View {
        if manager.isTopicMemoryReview || (showsMemoryReviewCards && manager.isMemoryReviewSession) {
            // The deck has a session bar where the strip stood: a stepper of
            // topics, or of sources in a review planned source by source, and
            // the model picker out of the composer the card no longer shows
            // (docs/memory-design.md, "Review by topic"). A source-by-source
            // review in the conversation layout keeps the chip strip.
            MemoryReviewSessionBar(
                topics: memoryReviewCardSubjects,
                statusBySource: manager.memoryReviewStatusBySource,
                currentTopicID: manager.memoryReviewCurrentSourceID,
                isBusy: isTurnInFlight,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                separated: !showsMemoryReviewCards,
                select: { subject in selectMemoryReviewSubject(subject) }
            ) {
                if !manager.isTopicMemoryReview {
                    memoryReviewSourcesMenu
                }
                if hidesComposerForMemoryCard, !vm.isScreenRecordModeActive {
                    InlineModelPicker(task: .chat)
                        .id("chat-model")
                }
            }
        } else {
            memoryReviewSourceChipStrip
        }
    }

    /// What the chip strip offered on each source, in a review planned source
    /// by source whose deck has the session bar instead: open it, take it
    /// now, or take it out of the day.
    private var memoryReviewSourcesMenu: some View {
        let entries = memoryReviewStripEntries
        return Menu {
            ForEach(entries) { entry in
                let done = manager.memoryReviewStatusBySource[entry.id] != nil
                Menu(entry.title) {
                    if entry.article != nil {
                        Button("Open in Reader") { Task { await vm.openLinkedSourceInReader(entry.id) } }
                    }
                    if !done, entry.id != manager.memoryReviewCurrentSourceID {
                        Button("Take It Now") { Task { await steerMemoryReview(to: entry) } }
                            .disabled(isTurnInFlight)
                    }
                    Button("Not Something I Read") { Task { await removeMemoryReviewSource(entry) } }
                        .disabled(isTurnInFlight)
                }
            }
        } label: {
            Text(entries.count == 1 ? "1 source" : "\(entries.count) sources")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Today's sources")
        .accessibilityIdentifier("memory.bar.sources")
    }

    @ViewBuilder
    private var memoryReviewSourceChipStrip: some View {
        let entries = manager.isMemoryReviewSession ? memoryReviewStripEntries : []
        if !entries.isEmpty {
            MemoryReviewSourceStrip(
                sources: entries,
                statusBySource: manager.memoryReviewStatusBySource,
                currentSourceID: manager.memoryReviewCurrentSourceID,
                isBusy: manager.isGenerating || manager.isSearching || manager.isPreparingGeneration,
                bookCoverPath: { memoryReviewBookCoverPath(for: $0) },
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                separated: !showsMemoryReviewCards,
                steer: { source in
                    Task { await steerMemoryReview(to: source) }
                },
                open: { sourceID in
                    Task { await vm.openLinkedSourceInReader(sourceID) }
                },
                remove: { source in
                    Task { await removeMemoryReviewSource(source) }
                }
            )
        }
    }

    /// The strip's chips: the day's material in the order the plan takes it,
    /// chats included, then anything attached beside it. A chat is review
    /// material under its own session id without being a source row, so it has
    /// no article and is named from the briefing's header; leaving chats out
    /// hid the source a review opened on, and no chip was current
    /// (2026-09-22, twelve of that day's nineteen sources).
    private var memoryReviewStripEntries: [MemoryReviewStripEntry] {
        let attached = reviewSources
        let attachedByID = Dictionary(attached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [MemoryReviewStripEntry] = []
        var seen = Set<String>()
        for id in manager.memoryReviewMaterialInPlanOrder where seen.insert(id).inserted {
            if let article = attachedByID[id] ?? vm.articlesById[id] {
                guard vm.isSourceIncludedInKnowledge(article) else { continue }
                // Screen record mode (admin only): only the sources the take
                // may show. A morning's review is prepared from the whole
                // library, and its strip named the learner's own papers.
                guard vm.isVisibleInRecordingMode(article) else { continue }
                entries.append(MemoryReviewStripEntry(id: id, title: article.title, article: article))
            } else if let title = manager.memoryReviewMaterialTitles[id] {
                // A chat chip: in screen record mode only a chat the take shows.
                if vm.isScreenRecordModeActive {
                    guard let session = vm.reviewSessionLinks.first(where: { $0.id == id }),
                          vm.isVisibleInRecordingMode(session) else { continue }
                }
                entries.append(MemoryReviewStripEntry(id: id, title: title, article: nil))
            }
        }
        for article in attached where seen.insert(article.id).inserted {
            entries.append(MemoryReviewStripEntry(id: article.id, title: article.title, article: article))
        }
        return entries
    }

    /// Where the learner is in the walk this chat plays — step n of m, Back,
    /// Next, a jump to any step — as a strip under the title while a record is
    /// attached: a header widget, not a panel (walkthrough-design.md).
    @ViewBuilder
    private var walkthroughPlaybackStrip: some View {
        if let playback = manager.walkthroughPlayback {
            WalkthroughPlaybackStrip(
                title: playback.walkthrough.title,
                steps: playback.steps,
                currentIndex: playback.currentIndex,
                cardOrdinal: playback.currentStep.map {
                    playback.walkthrough.cardOrdinal(stepIndex: playback.currentIndex, card: playback.revealedBeatCount(of: $0))
                } ?? 0,
                cardCount: playback.walkthrough.cardCount,
                playedStepIDs: playback.playedStepIDs,
                canGoBack: playback.canGoBack,
                canGoNext: playback.canGoNext,
                isBusy: isTurnInFlight,
                // The stage's own Next is the way on; a second pair up here
                // only competes with it.
                showsStepControls: !walkthroughFillsPane,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                back: { Task { await manager.walkthroughBack() } },
                next: { Task { await manager.walkthroughNext() } },
                jump: { index in Task { await manager.showWalkthroughStep(at: index) } },
                leave: {
                    manager.leaveWalkthroughPlayback()
                    // Like the pane's ×, it lands on New chat's greeting
                    // (`StudioViewModel.leaveWalkthroughForNewChat`). A
                    // comparison pane cannot take the window's New chat, so
                    // it stays on the walk's chat.
                    if acceptsGlobalRequests { vm.requestNewChat() }
                }
            )
        }
    }

    /// Walk Through was pressed on a source. The walk is not a chat
    /// (walkthrough-design.md, "the walk leaves the chat"): when its
    /// questions already have a chat, that chat opens under the cards;
    /// otherwise the walk plays in this pane when it has nothing in it or is
    /// already this walk's, and in a fresh pane when it holds another
    /// conversation, which is left exactly as it is (product owner, 2026-09-22:
    /// "it's like over the chat where I'm in, it's so weird").
    @MainActor
    private func handleWalkthroughPlayRequest() async {
        guard let request = vm.readerWalkthroughPlayRequest else { return }
        defer { vm.readerWalkthroughPlayRequest = nil }
        // An animation's chat is about the sources the animation is about.
        let aboutSourceIDs = request.isAnimation
            ? (vm.artifacts.first(where: { $0.id == request.sourceID })?.sourceIDs ?? [])
            : [request.sourceID]
        if !manager.isPlayingWalkthrough(of: request.sourceID),
           let walkChatID = try? await vm.storage.loadWalkthroughProgress(request.sourceID)?.chatSessionID,
           walkChatID != manager.currentSessionID {
            if vm.reviewSessionLinks.isEmpty { await vm.loadReviewSessionLinks() }
            if vm.reviewSessionLinks.contains(where: { $0.id == walkChatID }) {
                readsNotebookTicksLive = false
                vm.setContextSources(aboutSourceIDs)
                sessionStore.requestOpen(sessionID: walkChatID, playingWalkthroughOf: request.sourceID)
                return
            }
        }
        // A walk opens in a chat of its own unless this one is empty or
        // already playing it (`walkthroughOpensNewChat`). A chat still
        // waiting to open here — the window's last chat after a relaunch — is
        // a conversation too, and the walk is the later intent, so the open
        // gives way to the new chat.
        if sessionStore.walkthroughOpensNewChat(of: request.sourceID) || requestedResumeSessionID != nil {
            if acceptsGlobalNavigationRequests, vm.reviewChatResumeSessionID != nil {
                vm.reviewChatResumeSessionID = nil
            }
            readsNotebookTicksLive = false
            vm.setContextSources(aboutSourceIDs)
            sessionStore.requestNewChat(playingWalkthroughOf: request.sourceID)
            return
        }
        await startWalkthroughPlayback(sourceID: request.sourceID)
    }

    /// Loads the subject's record into this chat and plays its first step —
    /// or, when this chat has played some of it already, points the Reader
    /// (or the animation's pane) at the step the learner is on. The subject
    /// is a source when the library has one by that id, else the animation.
    @MainActor
    private func startWalkthroughPlayback(sourceID: String) async {
        if vm.articlesById[sourceID] == nil {
            var artifact = vm.artifacts.first(where: { $0.id == sourceID })
            if artifact == nil {
                artifact = try? await vm.storage.loadArtifact(sourceID)
            }
            guard let artifact, artifact.isAnimation else { return }
            guard await manager.loadWalkthrough(forAnimation: artifact) else {
                if manager.chatTakesWalkthrough(of: sourceID) {
                    vm.showToast("\(artifact.title) has no walkthrough yet")
                }
                return
            }
            if let playback = manager.walkthroughPlayback, !playback.playedStepIDs.isEmpty {
                await manager.showWalkthroughStep(at: playback.currentIndex)
            } else {
                await manager.playWalkthroughStep(at: 0)
            }
            await vm.loadReviewSessionLinks()
            requestComposerFocus()
            return
        }
        guard let article = vm.articlesById[sourceID] else { return }
        // Not loaded either because the source has no walk, or because a chat
        // landed here while it was being read and keeps the pane
        // (`chatTakesWalkthrough`); only the first is news.
        guard await manager.loadWalkthrough(for: article) else {
            if manager.chatTakesWalkthrough(of: sourceID) {
                vm.showToast("\(vm.displayTitle(for: article)) has no walkthrough yet")
            }
            return
        }
        if let playback = manager.walkthroughPlayback, !playback.playedStepIDs.isEmpty {
            await manager.showWalkthroughStep(at: playback.currentIndex)
        } else {
            await manager.playWalkthroughStep(at: 0)
        }
        await vm.loadReviewSessionLinks()
        requestComposerFocus()
    }

    /// The × on a chip takes the source out of today's review: material the
    /// picker counted as read that the learner never actually read, or has no
    /// time for today. The manager records the removal on the session and its
    /// briefing. When the tutor was on that very source, the note goes now as
    /// the learner's own "skip", so the review moves on rather than waiting on
    /// a question about material that is gone; otherwise it rides with their
    /// next message.
    @MainActor
    private func removeMemoryReviewSource(_ source: MemoryReviewStripEntry) async {
        let note = await manager.removeMemoryReviewSource(source.id, availableArticles: vm.articles)
        await vm.loadReviewSessionLinks()
        if let note {
            await sendReviewChatMessage(MemoryReviewTopicCardFold.skipMessage(title: source.title), contextualContent: note)
        }
    }

    /// A click on the session bar's stepper: the current topic's question is
    /// already on the card, so nothing; a finished topic opens its card as a
    /// record; a waiting one is taken now, in the learner's own words, with
    /// the topic's id riding beside them so the tutor turns to the right one
    /// and writes its heading.
    @MainActor
    private func selectMemoryReviewSubject(_ topic: MemoryReviewCardSubject) {
        if topic.id == manager.memoryReviewCurrentSourceID { return }
        if manager.memoryReviewStatusBySource[topic.id] != nil {
            guard showsMemoryReviewCards else { return }
            let cards = MemoryReviewCardFold.cards(manager.chatMessages, byTopic: true)
            guard let index = cards.lastIndex(where: { $0.sourceID == topic.id }) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                memoryReviewCardIndex = index == cards.count - 1 ? nil : index
            }
            return
        }
        if let realTopic = manager.memoryReviewTopics.first(where: { $0.id == topic.id }) {
            Task { await steerMemoryReview(toTopic: realTopic) }
        } else if let entry = memoryReviewStripEntries.first(where: { $0.id == topic.id }) {
            Task { await steerMemoryReview(to: entry) }
        }
    }

    @MainActor
    private func steerMemoryReview(toTopic topic: MemoryReviewTopic) async {
        let request = MemoryReviewTopicCardFold.takeNowMessage(title: topic.title)
        let turn = "[ForeverLM] The learner chose \(topic.title) in the session bar; its topic id is \(topic.id). "
            + "Turn to it now: write its \(MemoryReviewSourceTurn.line(sourceID: topic.id)) line, then ask its opening question."
        await sendReviewChatMessage(request, contextualContent: turn)
    }

    /// A click on a chip in the strip is a steer to that source: on one already
    /// checked off it asks to go deeper, on one still waiting it asks to take
    /// it now. Sent as the learner's own words, the way the Next and Go deeper
    /// chips are, with the source's id riding beside the message so the tutor
    /// turns to the right one and writes its heading.
    @MainActor
    private func steerMemoryReview(to source: MemoryReviewStripEntry) async {
        let reviewed = manager.memoryReviewStatusBySource[source.id] != nil
        // The source whose contour is open and unanswered is the question
        // already on the card. Asking to "do it now" only re-asks it, and on
        // 2026-09-26 the second wording listed the very ideas the first had
        // left to memory.
        if !reviewed, source.id == manager.memoryReviewCurrentSourceID { return }
        var note: String?
        if manager.offersMemoryReviewSteer, source.id == manager.memoryReviewCurrentSourceID {
            // The source under discussion, once graded: that is the Go deeper
            // chip by another route, so it is recorded as that steer, and a
            // contour that came back whole gets its understanding probe.
            note = await manager.steerMemoryReview(.deeper)
        }
        let request = reviewed
            ? MemoryReviewTopicCardFold.deeperOnMessage(title: source.title)
            : MemoryReviewTopicCardFold.takeNowMessage(title: source.title)
        let probe = note == nil
            ? "ask one probe there, chosen from the ideas its contour grade marked missing or partial."
            : "ask the understanding probe described above."
        let turn = "[ForeverLM] The learner clicked \(source.title) in the review strip; its source id is \(source.id). "
            + "Turn to it now: write its \(MemoryReviewSourceTurn.line(sourceID: source.id)) line, then "
            + (reviewed ? probe : "ask its contour.")
        await sendReviewChatMessage(request, contextualContent: [note, turn].compactMap { $0 }.joined(separator: "\n\n"))
    }

    /// A book chapter's row should draw the book's cover, not the first picture
    /// inside that chapter. Same lookup the shelf and the notepad chips use.
    private func memoryReviewBookCoverPath(for article: StudioArticle) -> String? {
        guard let group = article.parentGroup else { return nil }
        return vm.bookCoverPaths[group]
    }

    private var usesTitlebarBandHeader: Bool {
        usesDockedHeaderChrome && titlebarBandHeight != nil
    }

    /// Empty space kept under the last row of the transcript.
    ///
    /// While a reply streams, reserve the lower half of the viewport so the
    /// just-sent message can sit at the center and the answer streams in
    /// beneath it instead of starting at the bottom edge. Once the turn
    /// settles, keep a smaller band so a finished answer still reads with room
    /// under it rather than butting up against the composer.
    private var transcriptBottomReserve: CGFloat {
        // A card holds its exchange in its middle; there is nothing to
        // centre a sent answer against.
        guard transcriptViewportHeight > 0, !showsMemoryReviewCards else { return 0 }
        if manager.isGenerating || manager.isSearching {
            return transcriptViewportHeight / 2
        }
        // Proportional on a short panel, so the band never eats a bottom-sheet
        // popover's few visible rows.
        return min(96, transcriptViewportHeight * 0.25)
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The rows live in their own view so a streamed token
                // re-evaluates them and not this panel. Everything handed down
                // here changes at most a few times per turn.
                ReviewChatTranscriptStack(
                    manager: manager,
                    proxy: proxy,
                    isTurnInFlight: isTurnInFlight,
                    walkthroughPreparation: manager.walkthroughPreparationDetail,
                    turnStartedAt: turnStartedAt,
                    errorMessage: manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage,
                    bottomReserve: transcriptBottomReserve,
                    showsMemoryCards: showsMemoryReviewCards,
                    showsTopicCards: showsMemoryReviewCards,
                    answersAfterGrade: !manager.isTopicMemoryReview,
                    sendMemoryAnswer: { text in Task { await sendReviewChatMessage(text) } },
                    dontRememberMemoryAnswer: {
                        Task { await sendReviewChatMessage(MemoryReviewTutoring.dontRememberMessage) }
                    },
                    memoryCardIndex: memoryReviewCardIndex,
                    minContentHeight: showsMemoryReviewCards ? transcriptViewportHeight : 0,
                    columnMaxWidth: showsMemoryReviewCards ? memoryReviewCardTextWidth : chatColumnMaxWidth,
                    messageMaxWidth: showsMemoryReviewCards
                        ? memoryReviewCardTextWidth - 2 * MemoryReviewCardSurface.contentInset
                        : chatMessageMaxWidth,
                    returnQueuedFollowUp: { item in returnQueuedFollowUpToComposer(item) },
                    sendQueuedFollowUpNow: { item in Task { await manager.sendQueuedFollowUpNow(item.id) } },
                    openContextSource: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } },
                    answerOpenQuestion: { returnToOpenQuestion() },
                    skipOpenQuestion: { Task { await skipOpenQuestion() } },
                    followUpSideQuestion: { followUpSideQuestion() },
                    openSideQuestionInNewChat: { openSideQuestionInNewChat() },
                    laneExpansionRequest: laneExpansionRequest,
                    citationContexts: $citationContexts,
                    row: { block, context in
                        chatTranscriptBlock(block, context: context)
                    },
                    errorText: { message in
                        errorText(message)
                    }
                )
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                transcriptViewportHeight = height
            }
            // Started here rather than in the indicator's own `onAppear`: it sits
            // at the end of a LazyVStack, so scrolling away mid-turn would tear it
            // down and the clock would restart at zero on the way back.
            .onChange(of: showsWorkingLine, initial: true) { _, working in
                turnStartedAt = working ? (turnStartedAt ?? Date()) : nil
            }
            .contentShape(Rectangle())
            .onDrop(
                of: reviewChatDropTypes,
                isTargeted: dropTargetBinding,
                perform: handleDrop
            )
            .overlay {
                if dragVisibility.isDragging {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: reviewChatDropTypes,
                            isTargeted: dropTargetBinding,
                            perform: handleDrop
                        )
                }
            }
        }
    }

    private var sessionBrowserPopover: some View {
        ReviewSessionsPanel(
            compact: false,
            currentSessionID: {
                manager.currentSessionID
            },
            resumeSession: { session in
                isSessionBrowserPresented = false
                Task { await openPickedSession(session) }
            },
            hideSidebar: {
                isSessionBrowserPresented = false
            },
            hideButtonSystemImage: "xmark",
            hideButtonHelp: "Close previous chats",
            deletedActiveSession: {
                closeDeletedActiveSession()
            }
        )
        .frame(width: sessionBrowserPopoverWidth, height: sessionBrowserPopoverHeight)
    }

    @ViewBuilder
    private func chatTranscriptBlock(
        _ block: ReviewChatTranscriptBlock,
        context: ReviewChatTranscriptRowContext
    ) -> some View {
        if block.userMessage == nil, let marker = block.answerMessages.first?.walkthroughStep {
            // Only a walk that is not playing leaves a step turn in the
            // transcript (`WalkthroughTranscriptFold.resting`): its cards
            // come back from here.
            WalkthroughResumeRow(
                title: walkthroughSubjectTitle(marker.sourceID),
                maxContentWidth: chatMessageMaxWidth,
                resume: { Task { await startWalkthroughPlayback(sourceID: marker.sourceID) } }
            )
        } else if let message = block.userMessage {
            // Sources the learner brought in just before this message, above
            // it: their gesture, on their side (`ChatContextAdditions`).
            let stored = ChatContextAdditions.parse(contextContent: message.contextualContent)
            if !stored.added.isEmpty {
                ReviewChatContextAdditionsRow(
                    added: stored.added,
                    maxContentWidth: chatMessageMaxWidth,
                    openSource: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } }
                )
            }
            // The moment of a video the question was asked at, with the frame
            // the tutor was shown; a click plays the video from there.
            let moments = ReviewChatVideoMomentRow.moments(in: stored.onScreen)
            if !moments.isEmpty {
                ReviewChatVideoMomentRow(
                    moments: moments,
                    maxContentWidth: chatMessageMaxWidth,
                    open: { sourceID, seconds in
                        Task { await vm.openLinkedSourceInReader(sourceID, at: Double(seconds)) }
                    }
                )
            }
            chatTranscriptMessage(message)
        } else if showsMemoryReviewCards,
                  let opening = MemoryReviewTopicCardFold.opening(in: block.answerMessages)
                    ?? (context.isFirstOnCard ? MemoryReviewTopicCardFold.untitledOpening(in: block.answerMessages) : nil) {
            // The block that opens a card is its question, not a reply: set
            // large, its sources as faces under it, no footer.
            memoryReviewTopicOpening(opening, subjectID: opening.topicID.isEmpty ? context.memoryCardTopicID : opening.topicID)
            memoryReviewTopicLedgerAndSteer(context: context)
        } else {
            let replyLine = ReviewChatTranscriptSection.replyLine(of: block)
            ReviewChatAnswerBlock(
                messages: block.answerMessages,
                showsActions: !context.isLive,
                // A topic card's reply icons show under the pointer only.
                isLatest: context.isLatest && !showsMemoryReviewCards,
                saveToNote: context.isLive || replyLine == nil
                    ? nil
                    : ReviewChatSaveToNoteControl(
                        savedDocID: answerNoteDocIDs[block.id],
                        save: { Task { await saveAnswerToNote(block) } },
                        open: { docID in vm.revealArtifact(docID, in: windowState) }
                    ),
                // The answer as an Idea on the open canvas, where canvases are listed.
                addToCanvas: context.isLive || replyLine == nil || showsMemoryReviewCards || !vm.listsCanvases
                    ? nil
                    : { Task { await vm.addAnswerToCanvas(markdown: ReviewChatSaveToNote.markdown(of: block.answerMessages)) } },
                canFork: !manager.isGenerating &&
                    !manager.isSearching &&
                    block.answerMessages.contains(where: {
                        $0.exchangeID != nil && $0.exchangeField != nil
                    }),
                fork: {
                    forkConversation(through: block.answerMessages)
                },
                discussInNewChat: discussInNewChatAction(for: block.answerMessages),
                // Every finished reply offers both doors: an aside about it,
                // and the tutor expanding it. Neither moves the conversation.
                sideQuestion: context.isLive
                    ? nil
                    : ReviewChatSideQuestionControl(
                        isArmed: isSideQuestionMode && sideQuestionTarget?.blockID == block.id,
                        isFollowUp: context.isInsideAside,
                        toggle: {
                            toggleSideQuestionMode(about: ReviewChatReplyReference(blockID: block.id, line: replyLine))
                        }
                    ),
                moreDetails: context.isLive || replyLine == nil
                    ? nil
                    : {
                        requestMoreDetails(
                            about: ReviewChatReplyReference(blockID: block.id, line: replyLine),
                            existingLaneID: context.moreDetailsLaneID
                        )
                    },
                // A side question's lane has its own Skip, on its Back to
                // the question card.
                skipQuizQuestion: offersCourseQuizSkip(context: context)
                    ? { Task { await skipCourseQuizQuestion() } }
                    : nil,
                asideActionsOnly: showsMemoryReviewCards
            ) {
                // Every step the reply took is one "Worked for" line where the
                // first ran; a topic card draws no thinking among them.
                ForEach(ReviewChatAnswerLayout.items(block.answerMessages, showsThinking: !showsMemoryReviewCards)) { item in
                    chatTranscriptItem(item, isLive: context.isLive)
                        .id(item.id)
                }
            }
            // The two steers a memory review offers once the source under
            // discussion is graded: under the graded reply, under each probe's
            // reply, and under the tutor's offer to move on or stay. They sit
            // under the newest settled reply only. A topic card has its
            // ledger and its two buttons instead.
            if showsMemoryReviewCards {
                memoryReviewTopicLedgerAndSteer(context: context)
            } else if context.isLatest, !context.isLive, manager.offersMemoryReviewSteer,
                      !manager.isGenerating, !manager.isSearching {
                memoryReviewSteerChips
            } else if let questions = suggestedQuestions(under: block, context: context) {
                // The questions the reply suggested, under its footer.
                ChatSuggestedQuestionCards(
                    questions: questions,
                    fontSize: chatBodyFontSize,
                    maxWidth: min(chatMessageMaxWidth, 42 * chatBodyFontSize),
                    send: askSuggestedQuestion
                )
            }
        }
    }

    /// The chat's body size at this pane's zoom, as the reply's web view sets it.
    private var chatBodyFontSize: CGFloat {
        (ChatMarkdownView.baseFontSize * uiZoomScale).rounded()
    }

    /// The suggested questions to draw under this block: only the newest
    /// settled answer's, in the conversation itself, and never in a quiz, a
    /// review or a walk, whose next step is the tutor's.
    private func suggestedQuestions(
        under block: ReviewChatTranscriptBlock,
        context: ReviewChatTranscriptRowContext
    ) -> [String]? {
        // `offersFollowUpQuestions` is false in a course quiz, a review, a
        // memory review and while a walk plays; a walk's own step rows are
        // checked too, for the turns it left behind.
        guard context.isLatest, !context.isLive, !context.isInsideAside,
              !manager.isGenerating, !manager.isSearching,
              manager.offersFollowUpQuestions,
              !block.answerMessages.contains(where: { $0.walkthroughStep != nil }),
              let questions = block.answerMessages.last(where: { $0.role == .assistant })?.followUpQuestions,
              !questions.isEmpty else { return nil }
        return questions
    }

    /// A suggested question, asked as the learner's message in this chat.
    /// The draft and any passage waiting in the composer stay where they are.
    private func askSuggestedQuestion(_ question: String) {
        // Asked here, never offered again in the notebook's guide.
        if let notebookID = linkedResearchNotebook?.id {
            vm.noteNotebookQuestionAsked(question, notebookID: notebookID)
            notebookQuestionsRevision &+= 1
        }
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(question)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(question)
        }
    }

    /// Save to note: the answer becomes a Doc in this chat's notebook, or an
    /// unfiled one outside a notebook, named after the question it answers.
    /// The toast and the footer's tick confirm it; nothing opens. Its picture
    /// lines become the Doc's own attachments before its body is first
    /// written, in a team notebook too (`createDocKeepingPictures`).
    @MainActor
    private func saveAnswerToNote(_ block: ReviewChatTranscriptBlock) async {
        guard answerNoteDocIDs[block.id] == nil,
              answersBeingSavedToNotes.insert(block.id).inserted else { return }
        defer { answersBeingSavedToNotes.remove(block.id) }
        let markdown = ReviewChatSaveToNote.markdown(of: block.answerMessages)
        guard !markdown.isEmpty else { return }
        let title = ReviewChatSaveToNote.title(
            learnerMessage: learnerMessage(answeredBy: block),
            chatTitle: savedChatTitle,
            answer: markdown
        )
        do {
            let snapshot = try await vm.createDocKeepingPictures(
                title: title,
                homeNotebookID: linkedResearchNotebook?.id,
                markdown: markdown
            )
            answerNoteDocIDs[block.id] = snapshot.artifact.id
        } catch {
            // A read-only team, or a picture this Mac cannot draw: the toast
            // says which, and nothing was saved.
            vm.showToast(error.localizedDescription)
        }
    }

    /// The learner's own words this answer replies to. A More details press
    /// is the app's, not theirs, so it names nothing.
    private func learnerMessage(answeredBy block: ReviewChatTranscriptBlock) -> String? {
        let messages = manager.chatMessages
        guard let firstID = block.answerMessages.first?.id,
              let start = messages.firstIndex(where: { $0.id == firstID }),
              let asked = messages[..<start].last(where: { $0.role == .user }),
              !asked.isMoreDetailsRequest else { return nil }
        return ReviewSessionManager.displayableMessageContent(role: .user, content: asked.content)
    }

    /// The chat's title as the rail lists it, renames included.
    private var savedChatTitle: String {
        let recordTitle = manager.currentSessionID.flatMap { sessionID in
            vm.reviewSessionLinks.first { $0.id == sessionID }?.title
        }
        if let recordTitle, !recordTitle.isEmpty { return recordTitle }
        return manager.topic
    }

    /// Skip, an icon in the newest reply's footer while a quiz question waits
    /// for its answer (product owner, 2026-09-27: "please do allow me to skip
    /// questions in a quiz too"). The memory review's steer chips, which
    /// never share a chat with a quiz, keep that spot to themselves.
    private func offersCourseQuizSkip(context: ReviewChatTranscriptRowContext) -> Bool {
        context.isLatest && !context.isLive && !context.isInsideAside &&
            !showsMemoryReviewCards && !manager.offersMemoryReviewSteer &&
            manager.courseQuizOpenQuestionNumber != nil && !isSkippingQuizQuestion &&
            !manager.isGenerating && !manager.isSearching
    }

    /// The quiz skips its question in the app first, so the skip holds on any
    /// model, then the learner's words go to the tutor with what comes next.
    @MainActor
    private func skipCourseQuizQuestion() async {
        guard !isSkippingQuizQuestion else { return }
        isSkippingQuizQuestion = true
        defer { isSkippingQuizQuestion = false }
        guard let note = await manager.skipOpenCourseQuizQuestion() else { return }
        await sendReviewChatMessage("Skip this question.", contextualContent: note)
    }

    /// A topic card's opening: what the tutor said before turning, the
    /// question set large until the topic is graded, and the topic's sources
    /// as faces (a click opens one in the Reader).
    private func memoryReviewTopicOpening(_ opening: MemoryReviewTopicOpening, subjectID: String?) -> some View {
        let topic = subjectID.flatMap { id in memoryReviewCardSubjects.first { $0.id == id } }
        let graded = subjectID.map { manager.memoryReviewStatusBySource[$0] != nil } ?? false
        return MemoryReviewTopicQuestion(preamble: opening.preamble, question: opening.question, isLarge: !graded) {
            if let topic {
                memoryReviewTopicFaces(topic)
            }
        }
    }

    private func memoryReviewTopicFaces(_ topic: MemoryReviewCardSubject) -> some View {
        HStack(spacing: 8) {
            ForEach(topic.sourceIDs, id: \.self) { sourceID in
                let article = memoryReviewFaceArticle(sourceID)
                MemoryReviewSourceFace(
                    title: memoryReviewSourceTitle(sourceID),
                    article: article,
                    bookCoverPath: article.flatMap(memoryReviewBookCoverPath),
                    size: 30,
                    open: article == nil ? nil : { Task { await vm.openLinkedSourceInReader(sourceID) } }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("memory.card.faces")
    }

    /// The article behind a face, or nil for a chat and for a source a screen
    /// recording may not show (the strip's rule).
    private func memoryReviewFaceArticle(_ sourceID: String) -> StudioArticle? {
        guard let article = vm.articlesById[sourceID], vm.isVisibleInRecordingMode(article) else { return nil }
        return article
    }

    /// The name of a review source or chat: the article's, or the briefing's
    /// for a chat, which has no article to carry its title.
    private func memoryReviewSourceTitle(_ sourceID: String) -> String {
        vm.articlesById[sourceID]?.title ?? manager.memoryReviewMaterialTitles[sourceID] ?? "a source"
    }

    /// Under the last reply on a topic card: the ledger of the topic's ideas
    /// once its opening answer is graded, and, on the newest card once the
    /// tutor has replied to a graded answer, Go deeper and Next topic.
    @ViewBuilder
    private func memoryReviewTopicLedgerAndSteer(context: ReviewChatTranscriptRowContext) -> some View {
        if context.isLastOnCard, !context.isLive,
           let topicID = context.memoryCardTopicID,
           let topic = memoryReviewCardSubjects.first(where: { $0.id == topicID }) {
            let rows = MemoryReviewTopicCardFold.ledgerRows(
                ideaIDs: topic.ideaIDs,
                states: manager.memoryReviewIdeaStates,
                statement: { manager.memoryReviewIdea($0)?.statement }
            )
            if !rows.isEmpty {
                MemoryReviewTopicLedger(
                    rows: rows,
                    sourceTitle: memoryReviewSourceTitle,
                    article: memoryReviewFaceArticle,
                    bookCoverPath: memoryReviewBookCoverPath,
                    isBusy: isTurnInFlight,
                    open: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } },
                    notRead: { sourceID in
                        let entry = MemoryReviewStripEntry(
                            id: sourceID,
                            title: memoryReviewSourceTitle(sourceID),
                            article: vm.articlesById[sourceID]
                        )
                        Task { await removeMemoryReviewSource(entry) }
                    }
                )
            }
            if context.memoryCardFoot == .steer {
                MemoryReviewTopicSteerButtons(
                    isBusy: isTurnInFlight,
                    nextTitle: topic.isTopic ? "Next topic" : "Next source",
                    deeper: { Task { await steerMemoryReview(.deeper) } },
                    next: { Task { await steerMemoryReview(.next) } }
                )
            }
        }
    }

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    private func updateMemoryGoalPresence(sessionID: String?) {
        if let sessionID, MemoryReviewSession.isMemorySession(sessionID) {
            goalTracker.present(manager, panel: memoryGoalPanelToken, sessionID: sessionID, storage: vm.storage)
        } else {
            goalTracker.dismiss(panel: memoryGoalPanelToken)
        }
    }

    /// The pane carried the review and now carries something else: the learner
    /// left it by a door other than the ×, so the workspace comes back with
    /// them. Only a move *off* the focused review counts — a pane arriving at
    /// it passes through states where it is showing something else, and those
    /// must not end a review that is only just beginning.
    private func leaveMemoryReviewFocusIfMovedOff(from previousSessionID: String?, to sessionID: String?) {
        guard let previousSessionID,
              previousSessionID != sessionID,
              vm.memoryReviewFocusSessionID == previousSessionID else { return }
        vm.leaveMemoryReviewFocus(sessionID: previousSessionID)
    }

    private var memoryReviewSteerChips: some View {
        HStack(spacing: 8) {
            memoryReviewSteerChip("Go deeper", systemImage: "arrow.down.right.circle", steer: .deeper)
            memoryReviewSteerChip("Next", systemImage: "arrow.right.circle", steer: .next)
            Spacer(minLength: 0)
        }
        .padding(.top, -6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory review steer")
    }

    private func memoryReviewSteerChip(
        _ title: String,
        systemImage: String,
        steer: MemoryReviewSteer
    ) -> some View {
        Button {
            Task { await steerMemoryReview(steer) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(steer == .next
            ? "Move on to the next source"
            : "Stay on this source for a probe: on what did not come back, or past what did")
        .accessibilityIdentifier(steer == .next ? "mac.chatMemoryNext" : "mac.chatMemoryDeeper")
    }

    /// A chip is a spoken steer typed for the learner: it records the steer on
    /// the graded exchange, then sends the word as their message so the tutor
    /// hears it the same way it would hear "next" said aloud.
    @MainActor
    private func steerMemoryReview(_ steer: MemoryReviewSteer) async {
        let note = await manager.steerMemoryReview(steer)
        let text = steer == .next ? "Next." : "Go deeper."
        await sendReviewChatMessage(text, contextualContent: note)
    }

    private func forkConversation(through messages: [ReviewSessionManager.Message]) {
        Task {
            guard let forkedSession = await manager.forkConversation(through: messages) else {
                return
            }
            await vm.loadReviewSessionLinks()
            vm.requestResumeReviewSession(forkedSession.id)
        }
    }

    @ViewBuilder
    private func chatTranscriptItem(
        _ item: ReviewChatAnswerLayout.Item,
        isLive: Bool
    ) -> some View {
        switch item {
        case .entry(let entry):
            chatTranscriptEntry(entry)
        case .work(let work):
            ReviewChatWorkFold(work: work, isLive: isLive)
        case .pages(_, let pages):
            ReviewChatPageCards(pages: pages)
        }
    }

    /// A row that stands on its own in a reply: its prose, a review's turn to
    /// a source or topic, or the cards a call saved. Thinking and tool steps
    /// are the reply's "Worked for" fold (`ReviewChatAnswerLayout`).
    @ViewBuilder
    private func chatTranscriptEntry(_ entry: ReviewChatTranscriptEntry) -> some View {
        if let message = entry.message {
            chatTranscriptMessage(message)
        } else if let turn = entry.sourceTurn {
            memoryReviewSourceTurnRow(turn)
        } else if entry.activities.count == 1, let activity = entry.activities.first,
                  activity.kind == .sourceTurn, let topicID = activity.turnTargetID {
            // A turn to a topic: a heading in the conversation. On a topic
            // card the opening block draws the turn as the card's question
            // and never reaches here.
            MemoryReviewTopicTurnRow(
                title: activity.title,
                kind: manager.memoryReviewTopics.first { $0.id == topicID }?.kind
            )
        } else if let saved = entry.savedCards {
            ReviewChatSavedCardsView(saved: saved)
        }
    }

    /// The heading the transcript shows when the tutor turns to a source. It
    /// wears the same thumbnail as the source's chip in the strip above, so
    /// the eye can carry one token between the two: the strip says where the
    /// day stands, the heading says where the conversation is right now.
    private func memoryReviewSourceTurnRow(
        _ turn: ReviewSessionManager.Message.ToolActivity.SourcePresentation
    ) -> some View {
        let sources = reviewSources
        let position = sources.firstIndex(where: { $0.id == turn.id })
        return MemoryReviewSourceTurnRow(
            source: turn.source,
            bookCoverPath: memoryReviewBookCoverPath(for: turn.source),
            position: position.map { ($0 + 1, sources.count) },
            open: { Task { await vm.openLinkedSourceInReader(turn.id) } }
        )
    }

    /// The name a resume row gives a walk: its source's, or its animation's.
    private func walkthroughSubjectTitle(_ id: String) -> String {
        if let article = vm.articlesById[id] { return vm.displayTitle(for: article) }
        return vm.artifacts.first(where: { $0.id == id })?.title ?? "this source"
    }

    /// A message in the transcript. A walkthrough step's own turn is drawn
    /// as the card above the chat while the walk plays and is filtered out of
    /// the transcript (`WalkthroughTranscriptFold.cardThread`); with no walk
    /// playing, the walk's turns fold to one resume row.
    private func chatTranscriptMessage(_ message: ReviewSessionManager.Message) -> some View {
        chatBubble(for: message)
    }

    /// The card the walk is on, above the chat — also while a Reader beside
    /// it shows the walk's source, which stays clear to read (product owner,
    /// 2026-09-23: "those cards should be over the chat on the left; not
    /// over the paper").
    @ViewBuilder
    private var walkthroughCardDeck: some View {
        if manager.walkthroughPlayback != nil {
            WalkthroughDeckView(
                manager: manager,
                isBusy: isTurnInFlight,
                maxCardHeight: max(220, (transcriptPanelHeight > 0 ? transcriptPanelHeight : transcriptHeight) * 0.6),
                fillsPane: walkthroughFillsPane,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                isFolded: $isWalkthroughCardFolded,
                articleForSourceID: { id in vm.articlesById[id] },
                enlargeAnimation: { expandedWalkthroughAnimation = $0 }
            )
        }
    }

    /// Whether the walk's card takes the whole pane (walkthrough-design.md,
    /// "2026-09-24: the card takes the pane"): a card is up and nothing has
    /// been said under it — no turn in flight, no reply, no error — so there
    /// is no conversation to leave room for. The walk's own work is not
    /// something said: a step being got ready keeps the stage, whose foot
    /// shows the wait (2026-09-29: giving way for it flipped the card to its
    /// compact form and back on every step and every reload of the record).
    /// The transcript is read only when no turn is in flight, so a streaming
    /// reply never re-renders the panel token by token. The bottom-sheet
    /// popover keeps the compact card.
    private var walkthroughFillsPane: Bool {
        guard fillsAvailableSpace,
              !isWalkthroughCardFolded,
              let playback = manager.walkthroughPlayback,
              let step = playback.currentStep,
              playback.playedStepIDs.contains(step.id),
              !isTurnInFlight,
              manager.errorMessage == nil else { return false }
        return WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: playback).isEmpty
    }

    /// Tells the window this chat is walking, so a click on a panel in the
    /// Reader answers its Find it card, and takes it back when the walk ends.
    private func registerWalkthroughDeck() {
        guard let windowState else { return }
        if manager.walkthroughPlayback != nil {
            if windowState.walkthroughDeckManager !== manager {
                windowState.walkthroughDeckManager = manager
            }
        } else if windowState.walkthroughDeckManager === manager {
            windowState.walkthroughDeckManager = nil
        }
    }

    private func chatBubble(for message: ReviewSessionManager.Message) -> some View {
        ReviewChatBubble(
            message: message,
            citationContext: citationContexts[message.id] ?? .init(),
            maxContentWidth: chatMessageMaxWidth,
            isSpeaking: speech.currentMessageID == message.id && speech.isSpeaking,
            isStreaming: manager.streamingMessageID == message.id,
            linkedNotebookTitle: nil,
            updateLinkedNotebook: nil,
            createNotebook: nil,
            deleteMessage: {
                deleteChatMessage(message)
            },
            canDelete: !manager.isGenerating && !manager.isSearching,
            speakMessage: {
                speakAssistantMessage(message)
            },
            stopSpeaking: {
                speech.stop()
            },
            discussInNewChat: discussInNewChatAction(for: [message]),
            openPassage: { passage in
                openPassageInReader(passage)
            },
            // A page this chat cites is added to its notebook as well.
            webSourcesNotebookID: linkedResearchNotebook?.id
        )
        .equatable()
    }

    /// Opens the source a learner turn's quoted passage was selected in, in
    /// the Reader beside the chat with the words flashed — the way back to
    /// where the question came from (product owner, 2026-09-20). A block from before
    /// the `Source ID:` line names no source; then the chat's one source is
    /// it, or the source whose title the block's `Context:` label carries,
    /// chosen only among this chat's own sources.
    private func openPassageInReader(_ passage: ChatPassageOrigin.Passage) {
        var sourceID = passage.sourceID
        if sourceID == nil {
            let chatSourceIDs = Array(manager.loadedSourceIDs)
            if chatSourceIDs.count == 1 {
                sourceID = chatSourceIDs.first
            } else if let title = passage.contextTitle {
                let matches = chatSourceIDs.filter {
                    vm.articlesById[$0]?.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
                }
                if matches.count == 1 { sourceID = matches.first }
            }
        }
        guard let sourceID else {
            vm.showToast("Source not found in library")
            return
        }
        Task { await vm.openLinkedSourceInReader(sourceID, passage: passage.quote, beside: .chat) }
    }

    // MARK: - Lifting an exchange out of a memory review

    /// True while this pane shows a memory review: the one chat whose turns
    /// offer to be discussed somewhere else, because here they are graded.
    private var isMemoryReviewChat: Bool {
        guard let sessionID = manager.currentSessionID else { return false }
        return MemoryReviewSession.isMemorySession(sessionID)
    }

    /// The action for a memory review's saved turn, or nil where the button
    /// must not appear: an ordinary chat, or a turn that has not reached
    /// storage and so has no exchange to lift.
    private func discussInNewChatAction(for messages: [ReviewSessionManager.Message]) -> (() -> Void)? {
        guard isMemoryReviewChat,
              let exchangeID = messages.last(where: { $0.exchangeID != nil })?.exchangeID else { return nil }
        return { discussInNewChat(exchangeID: exchangeID) }
    }

    /// Lifts one exchange out of this review into a new chat. The exchange is
    /// read back from storage rather than from the messages on screen so the
    /// grade's idea coverage and the exchange's own sources come with it, and
    /// the review stays exactly where it is: its transcript, the chips waiting
    /// on Next or Go deeper, and the goal clock are untouched.
    private func discussInNewChat(exchangeID: String) {
        guard let sessionID = manager.currentSessionID else { return }
        let reviewTitle = manager.topic
        let fallbackSourceIDs = manager.linkedSourceIDs
        let openBeside = onOpenNewChatBeside
        Task {
            do {
                let exchanges = try await vm.storage.loadReviewSessionExchanges(sessionID: sessionID)
                guard let exchange = exchanges.first(where: { $0.id == exchangeID }) else {
                    manager.errorMessage = "This exchange has not been saved yet, so it cannot be discussed elsewhere."
                    return
                }
                let sourceIDs = exchange.sourceRefs.isEmpty ? fallbackSourceIDs : exchange.sourceRefs
                let ideas = try await vm.storage.loadSourceIdeas(sourceIDs: sourceIDs, includeRetired: true)
                    .values.flatMap { $0 }
                let handoff = MemoryReviewChatHandoff(
                    exchange: exchange,
                    reviewTitle: reviewTitle,
                    ideas: ideas,
                    fallbackSourceIDs: fallbackSourceIDs
                )
                let request = ReaderSelectionExplanationRequest(reviewHandoff: handoff)
                if let openBeside {
                    openBeside(request)
                } else {
                    vm.requestChatAboutReviewExchange(request)
                }
            } catch {
                manager.errorMessage = error.localizedDescription
            }
        }
    }

    /// This pane was asked to open a new chat on handed-in context. The
    /// running conversation, if any, is parked the way New chat parks it; the
    /// context is staged as the pending chip and its sources are attached, and
    /// the composer takes focus with nothing typed in it.
    @MainActor
    private func handleNewChatHandoff() async {
        guard let handoff = sessionStore.pendingNewChatHandoff else { return }
        // A passage of a page the side chat is already working on joins that
        // chat, as ChatGPT's side chat continues one thread (product owner,
        // 2026-10-07: "you decide"; his 2026-09-29 rule already let a passage
        // join a chat on the same Doc): nothing is reset, a running turn keeps
        // running, and the passage waits under the composer beside what has
        // been typed. Checked before the park below, which a join must not do.
        if pageSideChat != nil, let opening = handoff.opening, let passage = handoff.request,
           opening.draft == nil, docPassageJoinsThisChat(passage) {
            defer { sessionStore.didConsumeNewChatHandoff(id: handoff.id) }
            pendingReaderSelection = passage
            for attachment in passage.imageAttachments { manager.attachImage(attachment) }
            let articles = (opening.sourceIDs.isEmpty ? passage.sourceIDs : opening.sourceIDs)
                .compactMap { vm.articlesById[$0] }
            if !articles.isEmpty { await addArticlesToChatContext(articles) }
            if let doc = opening.page.attachment { manager.addContextDoc(doc) }
            requestComposerFocus()
            return
        }
        // A running turn is parked in a fresh manager; the view is then rebuilt
        // around it and this task runs again with the same id, at which point
        // the store answers false and the staging below happens once.
        if sessionStore.prepareForNewChat(requestID: handoff.id) { return }
        defer { sessionStore.didConsumeNewChatHandoff(id: handoff.id) }

        // A walk this pane was playing is left the way its × leaves it, so
        // its outline comes off the page; its place is kept in its record.
        manager.leaveWalkthroughPlayback()
        manager.endSession()
        // A side question lifted out of a Notebook's quiz is filed beside it;
        // every other handoff — a Reader passage, Walk Through, What's New,
        // Find directions — is filed in the notebook its window holds, and
        // outside one starts an unfiled chat.
        // A page's side chat is filed in the page's Notebook, which frames the
        // chat as it frames one opened from the Notebook itself.
        let notebookID = handoff.request?.sideQuestionHandoff?.notebookID
            ?? handoff.opening?.page.notebookID
            ?? windowNotebookForNewChat
        linkedResearchNotebookID = notebookID.flatMap { vm.notebook(id: $0) != nil ? $0 : nil }
        clearComposer()
        manager.clearStagedSources()

        // What's New and Find directions go out as the new chat's first
        // turn; nothing waits under the composer.
        if let request = handoff.request, request.sendsAtOnce {
            Task { await startResearchUpdate(request) }
            return
        }

        pendingReaderSelection = handoff.request
        // A selection's pictures go into the new chat's tray with the passage.
        for attachment in handoff.request?.imageAttachments ?? [] { manager.attachImage(attachment) }

        // A new chat opened to play a walkthrough: the source attaches as the
        // walk's first step is played, and nothing waits under the composer.
        if let sourceID = handoff.walkthroughSourceID {
            await startWalkthroughPlayback(sourceID: sourceID)
            return
        }

        let articles = (handoff.opening?.sourceIDs ?? handoff.request?.sourceIDs ?? [])
            .compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        if let opening = handoff.opening {
            // The page rides along by identity, so `read_doc` is offered for
            // all of it; the excerpt in a passage's message is one section.
            if let doc = opening.page.attachment { manager.addContextDoc(doc) }
            // A Prompt block's words wait under the composer, the writer's to
            // edit and send; machine-inserted, so a typed word replaces them.
            if let words = opening.draft {
                draft = words
                lastInsertedDefaultPrompt = words
            }
        }
        requestComposerFocus()
    }

    /// Everything between the send and the finished reply. Preparation counts:
    /// source hydration and session setup happen before the request goes out and
    /// are indistinguishable, from the learner's chair, from waiting on tokens.
    private var isTurnInFlight: Bool {
        // Hydrating a saved chat borrows `isSearching` to hold the composer, but
        // it is not a turn: the transcript arriving is its own feedback, and a
        // "Searching your library" line flashing under a conversation the learner
        // just opened describes work nobody asked for.
        guard !manager.isResumingSession else { return false }
        return manager.isPreparingGeneration || manager.isSearching || manager.isGenerating
    }

    /// Whether the transcript ends in the working line: a turn in flight, or a
    /// walk getting a step ready. The walk is not a turn — nothing is queued
    /// behind it and the composer stays open — but from the learner's chair it
    /// is the same wait for something to appear, so it runs the same clock.
    private var showsWorkingLine: Bool {
        isTurnInFlight || manager.walkthroughPreparationDetail != nil
    }

    /// One rounded composer, as in ChatGPT's (product owner, 2026-10-06: "make the
    /// app more slick; kind of like the chatgpt app … fewer buttons and bells
    /// and whistles"): above the field only what the learner put there (a
    /// passage, pictures); in it the tokens that change how the next message
    /// is read; under it "+" on the leading edge, and the model and its
    /// effort, the mic and send or Stop on the trailing one. Since 2026-10-11
    /// it is Codex's (product owner: "make the chat experience more look
    /// chatgpt codex"): a solid card, with the notebook and what is in
    /// context, where the window does not already say it, on a grey tray
    /// behind its top edge, as Codex shows the project there
    /// (`ChatComposerStack`).
    private var inputBar: some View {
        ChatComposerStack(showsTray: showsComposerContextRow) {
            composerContextRow
        } card: {
            composerCard
        }
        .animation(.easeOut(duration: 0.18), value: showsComposerContextRow)
        .overlay(alignment: .topLeading) {
            ReviewSlashSuggestionsOverlay(
                composer: composer,
                slashCommands: slashCommands,
                mentions: composerMentions,
                resolveLiveArguments: { command, query in
                    await resolveSlashLiveArguments(for: command, query: query)
                },
                resolveMentions: { query in
                    await resolveMentionItems(matching: query)
                },
                onSelect: { acceptSlashSuggestion($0) }
            )
        }
        .contentShape(Rectangle())
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
        .animation(.easeOut(duration: 0.18), value: reviewSources.map(\.id))
        .animation(.easeOut(duration: 0.18), value: linkedResearchNotebookID)
        .animation(.easeOut(duration: 0.18), value: dictation.isRecording)
        .animation(.easeOut(duration: 0.18), value: dictation.isTranscribing)
        .animation(.easeOut(duration: 0.18), value: voiceConversationEnabled)
    }

    /// The card itself: the passage, the pictures, the field, and the row of
    /// controls under it.
    private var composerCard: some View {
        VStack(spacing: StudioDesign.Spacing.small) {
            readerSelectionChip
            pendingImagesRow

            // The box reads the draft itself; this pane only hands it the
            // callbacks, so a keystroke re-renders the box and not the pane.
            ReviewChatComposerBox(
                composer: composer,
                placeholder: chatInputPlaceholder,
                focusRequestID: pageSideChat != nil
                    ? sessionStore.composerFocusRequestID
                    : vm.reviewChatFocusRequestID,
                slashCommands: slashCommands,
                mentions: composerMentions,
                onSubmit: {
                    Task {
                        await submitComposer()
                    }
                },
                onAcceptSuggestion: { acceptSlashSuggestion($0) },
                onDismissSuggestions: { dismissSlashSuggestions() },
                onTextChange: { text in
                    fileDraft()
                    // The first words of a question pause a video playing
                    // beside the chat and start taking its frame.
                    manager.composerTextChanged(text)
                },
                onPasteImages: { pasted in
                    Task { await attachPastedImages(pasted) }
                },
                onSubmitSideQuestion: {
                    Task { await submitComposer(asSideQuestion: true) }
                },
                removeSideQuestionToken: isSideQuestionMode
                    ? { disarmSideQuestion() }
                    : nil,
                sideQuestionAbout: sideQuestionTokenAboutLine,
                guessQuestion: pendingGuessedQuestion?.typedText,
                skipGuess: pendingGuessedQuestion != nil
                    ? { Task { await sendPendingGuessedQuestion(guess: nil) } }
                    : nil,
                onRemoveQuote: {
                    quotedPassage = ""
                    fileDraft()
                },
                showsDeepResearchToken: showsDeepResearchToken,
                // The mode holds while a turn runs (`setAssistantMode`), as
                // the "+" menu's toggle shows by dimming.
                removeDeepResearchToken: showsDeepResearchToken && !manager.isSearching && !manager.isGenerating
                    ? { manager.setAssistantMode(.assistant) }
                    : nil
            )
            .contentShape(Rectangle())
            .onDrop(
                of: reviewChatDropTypes,
                isTargeted: dropTargetBinding,
                perform: handleDrop
            )

            // Every mode, Deep Research included, runs on the chat's
            // session-scoped model. "+" leads; the model, the mic and send
            // or Stop sit on the trailing edge, as in ChatGPT's composer.
            HStack(spacing: 8) {
                composerAddMenu

                if dictation.isRecording {
                    // The meter takes the rest of the row while the mic is
                    // open: it is the only thing worth looking at then, and
                    // the width is what makes it read as a waveform at all.
                    ReviewDictationWaveform(
                        levels: dictation.audioLevels,
                        seconds: dictation.recordingSeconds,
                        onStop: { Task { await finishManualDictationAndSend() } },
                        onKeepInDraft: { Task { await finishManualDictationIntoDraft() } }
                    )
                } else {
                    Spacer(minLength: 0)

                    // Screen record mode keeps the chip: the mode chooses which
                    // sources, chats and Pages show and hides the learner's name,
                    // never what the app can do (product owner, 2026-10-12: "the
                    // functionality of the app is no different").
                    InlineModelPicker(task: .chat)
                        // The chip always shows the model's whole name, so it
                        // takes its width before the row's Spacer.
                        .layoutPriority(1)

                    // The mic has nothing to do mid-turn; Stop takes the
                    // trailing edge below.
                    if !manager.canStopGeneration {
                        composerMicControl
                    }

                    // Only once the context is filling up: until then the ring
                    // asks nothing of the learner, and the ⋯'s Context and
                    // Cost… draws it with its breakdown open.
                    if let breakdown = manager.contextBreakdown,
                       isContextBreakdownRequested || Self.contextGaugeAsksForAttention(breakdown) {
                        ChatContextGauge(
                            breakdown: breakdown,
                            sessionCost: manager.sessionCost,
                            isBreakdownRequested: $isContextBreakdownRequested
                        )
                    }

                    // Last in the row so it sits flush right, where the
                    // send/stop control lives in every other chat composer.
                    if manager.canStopGeneration {
                        Button {
                            // Stop is "not that reply", not "not my next
                            // message": what was waiting goes back to the
                            // composer, to send again with one Return or to
                            // rewrite.
                            returnQueuedFollowUpsToComposer()
                            manager.stopGeneration()
                        } label: {
                            // Codex's Stop: a square on the same dark circle
                            // as send, in the place send was.
                            ChatComposerActionCircle(systemImage: "stop.fill", glyphSize: 10)
                        }
                        .buttonStyle(.hoverWash(in: Circle(), inset: -2, opacity: 0.12))
                        .help("Stop tutor response")
                        .accessibilityLabel("Stop tutor response")
                        .accessibilityIdentifier("mac.chatStop")
                    } else if !isManualDictationPending {
                        ReviewChatSendButton(
                            composer: composer,
                            hasAttachments: !manager.pendingImages.isEmpty,
                            // A team's shared transcript draws no composer.
                            isEnabled: !manager.isBusyOutsideTurn
                        ) {
                            Task { await submitComposer() }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .popover(isPresented: $isSessionBrowserPresented, arrowEdge: .top) {
                sessionBrowserPopover
            }
        }
        // Which plugins the `@` popup offers is the gateway's answer, asked
        // once and shared. Connecting happens on the web, so coming back to the
        // app is the moment a new plugin can appear.
        .task { await ChatPluginPresence.shared.refreshIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ChatPluginPresence.shared.refreshIfStale() }
        }
        .padding(.leading, StudioDesign.Spacing.medium)
        .padding(.trailing, StudioDesign.Spacing.small + 2)
        .padding(.top, StudioDesign.Spacing.medium)
        .padding(.bottom, StudioDesign.Spacing.small + 2)
        // A solid card, not glass, so source drops still reach the composer's
        // .onDrop and the field reads as paper the way Codex's does.
        .chatComposerCard(cornerRadius: Self.composerCornerRadius)
        .overlay {
            if showsComposerDropTarget {
                ReviewChatComposerDropTarget(
                    isTargeted: isDropTargeted,
                    payloadDescription: draggedPayloadDescription,
                    cornerRadius: Self.composerCornerRadius
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsComposerDropTarget)
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    /// The mic, or, while a dictated message is on its way to being sent,
    /// the transcribing mark with its way back into the draft.
    @ViewBuilder
    private var composerMicControl: some View {
        if isManualDictationPending, manualDictationResultDestination == .send {
            // The transcript is on its way to being sent. Until it lands
            // there is still time to change that: the X reroutes it into the
            // draft, where it can be read and edited first.
            HStack(spacing: 6) {
                ReviewDictationTranscribingIndicator()
                Button {
                    Task { await finishManualDictationIntoDraft() }
                } label: {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 8, weight: .semibold)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
                .help("Keep the transcript in the draft instead of sending it")
                .accessibilityLabel("Don't send the transcript")
                .accessibilityIdentifier("mac.chatDictation.cancelSend")
            }
        } else {
            Button {
                Task {
                    await dictation.startRecording()
                }
            } label: {
                recordButtonLabel
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
            .disabled(!canUseDictationButton)
            .help(dictationButtonHelp)
            .accessibilityLabel("Dictate message")
            .accessibilityIdentifier("mac.chatDictation")
        }
    }

    /// The ring is drawn once the request fills this much of the model's
    /// window: where its own colour turns from the accent to orange, the
    /// first point at which it asks for something (a new chat, fewer
    /// sources). Below it the ⋯'s Context and Cost… draws it with its breakdown open.
    static let contextGaugeAttentionFraction = 0.7

    static func contextGaugeAsksForAttention(_ breakdown: ReviewSessionManager.ChatContextBreakdown) -> Bool {
        breakdown.usedFraction >= contextGaugeAttentionFraction
    }

    /// The modes that are a kind of chat rather than a review or a summary,
    /// where Deep Research is one of the two the learner chooses between.
    private var offersDeepResearch: Bool {
        [.assistant, .shallowRead, .deepRead, .deepResearch].contains(manager.currentPromptMode)
    }

    /// The "Deep research" token at the head of the field.
    private var showsDeepResearchToken: Bool {
        offersDeepResearch && manager.isDeepResearchMode
    }

    /// "+" at the composer's leading edge, as in ChatGPT's: what can be added
    /// to the message, and Deep Research, which took the place of the
    /// always-visible Chat / Deep Research pill on 2026-10-06 (the product owner: "make
    /// the app more slick; kind of like the chatgpt app"). Its menu opens
    /// upward, like the model picker's, since the composer sits at the foot of
    /// the window (`UpwardMenuChip`).
    @ViewBuilder
    private var composerAddMenu: some View {
        if #available(macOS 14.4, *) {
            UpwardMenuChip {
                composerAddMenuItems
            } label: {
                composerAddMenuLabel
            }
            .modifier(ComposerAddMenuChrome())
        } else {
            Menu {
                composerAddMenuItems
            } label: {
                composerAddMenuLabel
            }
            .pickerPillMenu()
            .fixedSize()
            .modifier(ComposerAddMenuChrome())
        }
    }

    /// Codex's "+": full ink, a size up from the controls beside it.
    private var composerAddMenuLabel: some View {
        Image(systemName: "plus")
            .zoomedSystemFont(size: 15, weight: .regular)
            .foregroundStyle(.primary)
            .frame(width: 16, height: 18)
    }

    /// The "+" chip's help and accessibility, shared by both menu routes.
    private struct ComposerAddMenuChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .help("Add")
                .accessibilityLabel("Add")
                .accessibilityIdentifier("mac.chatAdd")
        }
    }

    @ViewBuilder
    private var composerAddMenuItems: some View {
        // What a drop from Finder does: a picture goes with the message, a
        // paper, book or text file into the library and this chat.
        Button {
            Task { await addFilesFromOpenPanel() }
        } label: {
            Label("Add Photos and Files…", systemImage: "paperclip")
        }
        // The source picker `/source` opens past its popup.
        Button {
            slashSourcePickerRequest = SlashSourcePickerRequest(seed: "")
        } label: {
            Label("Add Sources…", systemImage: "books.vertical")
        }
        if offersDeepResearch {
            Divider()
            // A Toggle, so the item's own state column shows it is on.
            Toggle(isOn: Binding(
                get: { manager.isDeepResearchMode },
                set: { manager.setAssistantMode($0 ? .deepResearch : .assistant) }
            )) {
                Label("Deep Research", systemImage: "globe")
            }
            .disabled(manager.isSearching || manager.isGenerating)
        }
    }

    /// Add Photos and Files…: the open panel, and then exactly what a drop
    /// of the same files from Finder does (`handleDrop`).
    @MainActor
    private func addFilesFromOpenPanel() async {
        let urls = await FilePanel.open { panel in
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = Self.chatImageDropTypes
                + supportedBookImportContentTypes
                + [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }
            panel.prompt = "Add"
        }
        for url in urls {
            if Self.isImageFile(url) {
                await attachImageFile(url)
                continue
            }
            let previousIDs = Set(vm.contextSourceIds)
            await vm.importDroppedFile(url: url)
            let newArticles = vm.contextSourceArticles.filter { !previousIDs.contains($0.id) }
            await addArticlesToChatContext(newArticles)
        }
    }

    // The record button carries the two quiet voice states; the loud one — the mic
    // actually being open — takes over the whole control row instead (see above).
    @ViewBuilder
    private var recordButtonLabel: some View {
        if dictation.isTranscribing {
            ReviewDictationTranscribingIndicator()
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
    }

    /// Context chips above the composer, echoing how coding assistants pin the
    /// working folder above their input: the canvas this chat was opened from
    /// and the cards added to it, the notebook this chat is filed in, then the
    /// sources and Docs it can reach that no chip already shows. A chat in no
    /// notebook shows no notebook chip, and there is no picker here (product
    /// owner, 2026-10-06: "too much"); a chat's notebook comes from the window
    /// it is opened in. They wrap, so a canvas with many cards takes a second
    /// line rather than the width.
    ///
    /// In its own notebook's window neither chip is drawn (2026-10-06, the
    /// ChatGPT composer: nothing over the field the learner did not put
    /// there): the window is that notebook, and its Sources column says what
    /// the chat reads, ticked, with "N of M in chat". A Page attached to the
    /// chat is the exception, since the Sources column does not list it.
    ///
    /// Since 2026-10-11 the row is the composer's tray, behind the card's top
    /// edge (`ChatComposerStack`), where Codex shows the project.
    ///
    /// What is open beside the chat has a chip too, in every window, a
    /// notebook's included (2026-10-13): the chat is told of it with every
    /// message, so the tray says so, and its × leaves it out
    /// (`onScreenChips`).
    @ViewBuilder
    private var composerContextRow: some View {
        let chips = composerContextChips
        if chips.showsAny {
            FlowLayout(spacing: 8) {
                if let canvasContext = manager.canvasContext {
                    canvasChips(canvasContext)
                }
                if chips.notebook {
                    notebookChip
                }
                onScreenChips(chips.onScreen)
                if chips.context {
                    attachedSourcesChip
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Which of the context row's chips are drawn: the notebook's outside its
    /// own window, the "in context" pill when something is (in the notebook's
    /// window only for an attached Page), the canvas's, and one for each
    /// source open beside the chat.
    private var composerContextChips: (notebook: Bool, context: Bool, onScreen: [ChatContextAdditions.OnScreen], showsAny: Bool) {
        let inOwnNotebookWindow = notebookGuideNotebook != nil
        let notebook = linkedResearchNotebook != nil && !inOwnNotebookWindow
        let context = contextItemCount > 0 && (!inOwnNotebookWindow || !manager.contextDocs.isEmpty)
        let onScreen = onScreenChipSources
        return (notebook, context, onScreen, notebook || context || !onScreen.isEmpty || manager.canvasContext != nil)
    }

    /// The library sources on screen in this chat's window, read as a
    /// message sent now reads them (`ChatOpenPanes.sourcesOnScreen`). Empty
    /// for a chat outside a Studio window.
    private var sourcesOnScreenBesideChat: [ChatContextAdditions.OnScreen] {
        guard let windowState else { return [] }
        return ChatOpenPanes.sourcesOnScreen(in: windowState, vm: vm)
    }

    /// The open sources the tray gives a chip: what the chat is told is on
    /// screen, less what the learner left out with a chip's ×, and less what
    /// the "in context" pill already counts, whose text the chat has read in
    /// and whose × is in that pill's list.
    private var onScreenChipSources: [ChatContextAdditions.OnScreen] {
        let leftOut = manager.onScreenSourcesLeftOut
        let loaded = manager.loadedSourceIDs
        return sourcesOnScreenBesideChat.filter { !leftOut.contains($0.id) && !loaded.contains($0.id) }
    }

    /// A chip for each source open beside the chat (product owner,
    /// 2026-10-13: "perhaps a chat should know at all times what is OPEN;
    /// i.e. it should know i have this youtube video open. and if i don't
    /// want to chat about that; i can click a small X and it will remove it
    /// from context"). The chat already reads what is on screen with every
    /// message, a video with its moment (`ChatContextAdditions.onScreen`);
    /// the chip shows it, and its × leaves the source out of this chat for
    /// as long as it stays open (`ReviewSessionManager.onScreenSourcesLeftOut`).
    /// The source is in front of the learner, so the chip opens nothing.
    @ViewBuilder
    private func onScreenChips(_ sources: [ChatContextAdditions.OnScreen]) -> some View {
        ForEach(sources, id: \.id) { source in
            ComposerRemovableChip(
                symbol: vm.articlesById[source.id]?.sourceType.symbolName ?? "doc",
                title: source.title,
                maxTitleWidth: 220,
                help: "Open beside this chat, so the chat sees it",
                removeHelp: "Leave \u{201C}\(source.title)\u{201D} out of this chat while it is open",
                accessibilityLabel: "Open beside the chat: \(source.title)",
                open: nil,
                remove: { manager.leaveOutOnScreenSource(source.id) }
            )
            .accessibilityIdentifier("chat.onScreenChip")
        }
    }

    /// Whether the composer draws its tray.
    private var showsComposerContextRow: Bool { composerContextChips.showsAny }

    /// The canvas this chat was opened from as a chip, and a chip for each of
    /// its cards the learner added (`KnowledgeMapChatChipRow`): a click shows
    /// the canvas or the card, an × takes the canvas, or the card from the
    /// next turn, out of the chat.
    @ViewBuilder
    private func canvasChips(_ context: KnowledgeMapChatContext) -> some View {
        KnowledgeMapChatChipRow(
            context: context,
            symbol: { card in
                vm.knowledgeMap.nodesByRef[card.ref].map(KnowledgeMapCardGlyph.symbol(for:)) ?? "rectangle.on.rectangle"
            },
            showCanvas: { vm.showKnowledgeMapChatCanvas(context.canvasID, in: windowState) },
            showCard: { ref in
                Task { await vm.showKnowledgeMapChatCard(ref, canvasID: context.canvasID, in: windowState) }
            },
            removeCard: { manager.removeCanvasCard($0) },
            removeCanvas: { manager.removeCanvasContext() }
        )
    }

    @ViewBuilder
    private var notebookChip: some View {
        if let notebook = linkedResearchNotebook {
            Button {
                vm.openNotebookInReader(notebook.id)
            } label: {
                notebookChipLabel(notebook)
            }
            .buttonStyle(ComposerChipButtonStyle())
            .help("This chat works in \u{201C}\(NotebookTitle(notebook.title).text)\u{201D} — click to open the notebook")
            .accessibilityLabel(notebookChipAccessibilityLabel(notebook))
            .contextMenu { OtherWindowMenuItem(.notebook(notebook.id)) }
        }
    }

    private func notebookChipLabel(_ notebook: LearningGoalRecord) -> some View {
        HStack(spacing: 5) {
            let notebookTitle = NotebookTitle(notebook.title)
            NotebookIconView(notebookID: notebook.id, size: 14, cornerRadius: 3) {
                Text(notebookTitle.displayIcon)
                    .font(.caption2)
            }
            .accessibilityHidden(true)
            Text(notebookTitle.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let summary = notebookSelectionSummary {
                Text("\u{00B7} \(summary)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        // On the tray the notebook reads in full ink, as Codex's project does.
        .font(.callout)
        .foregroundStyle(.primary)
    }

    private func notebookChipAccessibilityLabel(_ notebook: LearningGoalRecord) -> String {
        "Notebook: \(NotebookTitle(notebook.title).text)"
            + (notebookSelectionSummary.map { ", \($0) sources" } ?? "")
    }

    /// New Notebook from This Chat: the notebook made at once, carrying what
    /// the open chat holds beyond its record.
    private func requestNotebookFromChat(_ sessionID: String) {
        notebookFromChatRequest = NotebookFromChatRequest(
            sessionID: sessionID,
            title: selectedChatTitle ?? "",
            openChatSourceIDs: manager.linkedSourceIDs + manager.loadedSourceIDs.sorted()
        )
    }

    /// What this chat is holding, shown above the composer so a drag-in or an
    /// attached Doc gives immediate visible confirmation. "In context" means
    /// source text the model has actually read plus the Docs it can read on
    /// demand. The wider pool it could reach is not counted here: a Notebook is
    /// a focus, not a wall, the whole library stays searchable from any chat,
    /// and the learner narrows or widens a question by asking ("only this
    /// Notebook's sources", "anything in my library"), so a pool size above the
    /// composer answered a question nobody was asking.
    ///
    /// Nothing in context, no chip. An attached Doc or a dragged-in source
    /// shows it on its own, so an explicit gesture never looks like it did
    /// nothing.
    @ViewBuilder
    private var attachedSourcesChip: some View {
        if contextItemCount > 0 {
            Button {
                isContextSourcesPopoverPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(loadedContextSummary)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: contextItemCount)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        Color.primary.opacity(
                            isContextSourcesPopoverPresented ? 0.09
                                : (isContextSourcesChipHovering ? 0.06 : 0)
                        )
                    )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isContextSourcesChipHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isContextSourcesChipHovering)
            .help("Show what this chat has read in")
            .accessibilityLabel("\(contextItemCount) items in context")
            .popover(isPresented: $isContextSourcesPopoverPresented, arrowEdge: .top) {
                contextSourcesPopover
            }
        }
    }

    /// Everything the chat is actually holding that no chip shows: sources
    /// whose text was read in, plus Docs attached by identity, less the ones a
    /// canvas card's chip already names. One number, because the learner asked
    /// one question — what is in the context?
    private var contextItemCount: Int {
        KnowledgeMapChatChips.pillCount(
            loadedSourceIDs: loadedSources.map(\.id),
            docIDs: manager.contextDocs.map(\.id),
            cards: manager.canvasContext?.cards ?? []
        )
    }

    /// What the "In context" popover lists: the sources and Docs the pill
    /// counts. Taking a card's chip away leaves its source or Doc here, to be
    /// removed from the context as any is.
    private var sourcesOutsideChips: [StudioArticle] {
        let shown = KnowledgeMapChatChips.sourceIDs(shownBy: manager.canvasContext?.cards ?? [])
        return loadedSources.filter { !shown.contains($0.id) }
    }

    private var docsOutsideChips: [ChatDocAttachment] {
        let shown = KnowledgeMapChatChips.docIDs(shownBy: manager.canvasContext?.cards ?? [])
        return manager.contextDocs.filter { !shown.contains($0.id) }
    }

    private var loadedContextSummary: String {
        "\(contextItemCount) in context"
    }

    /// What the assistant has actually read — not what it could reach.
    private var contextSourcesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("In context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if contextItemCount > 0 {
                    Text("\(contextItemCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if contextItemCount == 0 {
                Text("Nothing loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Docs first: a Doc is attached deliberately, one at a
                        // time, while sources arrive by the dozen from a pool.
                        ForEach(docsOutsideChips) { doc in
                            ContextDocCard(doc: doc) {
                                manager.removeContextDoc(doc.id)
                            }
                        }
                        ForEach(sourcesOutsideChips) { source in
                            ContextSourceCard(
                                source: source,
                                metadataVisibility: metadataVisibility,
                                onOpen: {
                                    isContextSourcesPopoverPresented = false
                                    Task { await vm.openLinkedSourceInReader(source.id) }
                                },
                                onRemove: { removeSourceFromChatContext(source.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }

        }
        .frame(width: contextSourcesPopoverWidth)
        .frame(maxHeight: contextSourcesPopoverHeight)
    }

    /// Where this conversation came from, once it has been written down: the
    /// header ⋯'s "Open “<page>” — <section>", falling back to the page alone
    /// when the passage sat under no heading. It brings the page forward, so
    /// the round trip with the page's Discussion closes in both directions.
    /// A line over the composer said "From <page> — <section>" for the whole
    /// chat until 2026-10-06 (the ChatGPT composer: nothing stays over the
    /// field that the learner did not just put there).
    private func docOriginMenuTitle(for entry: ArtifactChatLink) -> String {
        let title = vm.artifacts.first { $0.id == entry.link.artifactID }?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let docName = "\u{201C}\((title?.isEmpty == false ? title : nil) ?? "Untitled page")\u{201D}"
        guard !entry.link.sectionTitle.isEmpty else { return "Open \(docName)" }
        return "Open \(docName) — \(entry.link.sectionTitle)"
    }

    /// `StudioAssistantSessionStore.docPassageJoinsOpenChat`, with the doc
    /// links read for the chat on screen. Links still loaded for the chat
    /// shown before it do not count, and neither does this chat while another
    /// is on its way into the pane.
    private func docPassageJoinsThisChat(_ request: ReaderSelectionExplanationRequest) -> Bool {
        guard requestedResumeSessionID == nil else { return false }
        let sessionID = manager.currentSessionID
        let linkedDocIDs = Set(sessionDocLinks.lazy.filter { $0.link.sessionID == sessionID }.map(\.link.artifactID))
        return sessionStore.docPassageJoinsOpenChat(request, linkedDocIDs: linkedDocIDs)
    }

    @MainActor
    private func reloadSessionDocLinks() async {
        guard let sessionID = manager.currentSessionID else {
            sessionDocLinks = []
            return
        }
        sessionDocLinks = await vm.chatDocLinks(sessionID: sessionID)
    }

    /// Pictures waiting to go with the next message.
    @ViewBuilder
    private var pendingImagesRow: some View {
        if !manager.pendingImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.pendingImages) { attachment in
                        PendingChatImageChip(attachment: attachment) {
                            manager.removePendingImage(attachment.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .accessibilityLabel("\(manager.pendingImages.count) attached \(manager.pendingImages.count == 1 ? "image" : "images")")
        }
    }

    @ViewBuilder
    private var readerSelectionChip: some View {
        if let selection = pendingReaderSelection {
            HStack(spacing: 5) {
                Image(systemName: readerSelectionChipIcon(for: selection))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(readerSelectionPreview(for: selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button {
                    pendingReaderSelection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(opacity: 0.12))
                .help(readerSelectionChipRemoveHelp(for: selection))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(readerSelectionChipKindLabel(for: selection) + readerSelectionPreview(for: selection))
        }
    }

    private func readerSelectionChipIcon(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return MemoryReviewSession.sidebarIcon }
        if selection.sideQuestionHandoff != nil { return "arrow.turn.down.right" }
        if selection.isPictureOnly { return "photo" }
        return "text.quote"
    }

    private func readerSelectionChipRemoveHelp(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return "Remove the review exchange from chat context" }
        if selection.sideQuestionHandoff != nil { return "Remove the side question from chat context" }
        if selection.isPictureOnly { return "Remove the selected picture's note from chat context" }
        return "Remove selected passage from chat context"
    }

    private func readerSelectionChipKindLabel(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return "From the memory review: " }
        if selection.sideQuestionHandoff != nil { return "From a side question: " }
        if selection.isPictureOnly { return "Selected picture: " }
        return "Selected passage: "
    }

    /// Notebook titles come from current app state, so `/notebook` can offer deterministic
    /// identity choices without asking the model to decide which stored record was meant.
    private var slashCommands: [ReviewSlashCommand] {
        var commands = ReviewSlashCommand.all.map { command in
            guard command.kind == .notebook else { return command }
            return command.withArguments(
                vm.notebooks
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    .map {
                        ReviewSlashCommand.Argument(value: $0.title, display: "Switch to this notebook")
                    }
            )
        }
        // The learner's skills follow the app's own commands. A name is taken
        // once — the store refuses a built-in's name, and two skills of one
        // name (two Macs, before sync met) offer the newer edit.
        var taken = Set(commands.map(\.name))
        for skill in SkillLibrary.shared.skills.sorted(by: { $0.updatedAt > $1.updatedAt }) where !taken.contains(skill.name) {
            taken.insert(skill.name)
            commands.append(.skill(skill))
        }
        return commands
    }

    private var pluginPresence: ChatPluginPresence { ChatPluginPresence.shared }

    /// The connected plugins the open chat can ask — one per plugin this
    /// chat's mode can read, so the `@` popup never offers a question the model
    /// has no tool to answer. The send reads the same list, so a mention is
    /// recognised exactly where it was offered.
    private var chatPlugins: [ChatPlugin] {
        pluginPresence.plugins(availableIn: manager.currentPromptMode)
    }

    /// `@slack`, `@linear`, `@github` as the popup offers them.
    private var composerMentions: [ReviewComposerMention] {
        chatPlugins.map { $0.mention(slackWorkspaces: pluginPresence.slackWorkspaces) }
    }

    /// The open chat's record when it is a transcript a team shared. Such a
    /// chat is a snapshot: it has no tutor to answer and nothing to send.
    private var teamSnapshotRecord: ReviewSessionRecord? {
        guard let sessionID = manager.currentSessionID,
              let record = vm.reviewSessionLinks.first(where: { $0.id == sessionID }),
              record.isTeamSnapshot else { return nil }
        return record
    }

    private func sharedTranscriptFooter(_ snapshot: ReviewSessionRecord) -> some View {
        let teamName = snapshot.teamID.flatMap { vm.team(id: $0)?.name }
        return HStack(spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 11, weight: .medium))
            Text(teamName.map { "Shared transcript from \($0)" } ?? "Shared transcript")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, StudioDesign.Spacing.medium)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("chat.sharedTranscriptFooter")
    }

    private var canSubmitComposer: Bool {
        // Sending while a reply is still generating is allowed: the message is
        // queued, drawn under the running turn, and answered as soon as that
        // turn finishes. Only work outside a turn holds the composer — a saved
        // chat hydrating, sources being attached — because there is no turn for
        // the message to follow. A team's transcript snapshot never sends.
        teamSnapshotRecord == nil &&
        !manager.isBusyOutsideTurn &&
        (
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            // A quoted passage on its own is a message: it asks about itself.
            !quotedPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !manager.pendingImages.isEmpty ||
            dictation.isRecording ||
            dictation.isTranscribing ||
            manualDictationTranscriptionTask != nil
        )
    }

    private var isManualDictationPending: Bool {
        dictation.isRecording || dictation.isTranscribing || manualDictationTranscriptionTask != nil
    }

    /// These are the conditions where the control genuinely cannot act: a turn
    /// in flight or a recording still being transcribed.
    private var canUseDictationButton: Bool {
        !manager.isSearching &&
        !manager.isGenerating &&
        !dictation.isTranscribing &&
        manualDictationTranscriptionTask == nil
    }

    private var dictationButtonHelp: String {
        if dictation.isRecording { return "Stop dictation and send" }
        if dictation.isTranscribing { return "Transcribing…" }
        return "Dictate answer"
    }

    // MARK: - Side questions

    /// The newest stretch of the transcript, grouped the way the transcript
    /// draws it: an ordinary block, or a side question's lane. Newest by
    /// time, not by position: a lane about an older reply is drawn up under
    /// that reply.
    private var newestTranscriptSection: ReviewChatTranscriptSection? {
        guard !manager.chatMessages.isEmpty else { return nil }
        let blocks = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
        return ReviewChatTranscriptSection.newest(in: ReviewChatTranscriptSection.grouping(blocks), blocks: blocks)
    }

    /// The newest ordinary reply — the one an aside is about when nothing
    /// names another — as the mark beside the aside refers to it.
    private var newestReplyReference: ReviewChatReplyReference? {
        let blocks = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        // Inside a lane, the reply the lane is about; otherwise the last reply.
        if let newest = ReviewChatTranscriptSection.newest(in: sections, blocks: blocks),
           newest.isSideQuestion, let aboutID = newest.aboutBlockID,
           let block = blocks.first(where: { $0.id == aboutID }) {
            return ReviewChatReplyReference(blockID: block.id, line: ReviewChatTranscriptSection.replyLine(of: block))
        }
        guard let block = sections.last(where: { section in
            !section.isSideQuestion && section.blocks.contains { $0.userMessage == nil }
        })?.blocks.last(where: { $0.userMessage == nil }) else {
            return nil
        }
        return ReviewChatReplyReference(blockID: block.id, line: ReviewChatTranscriptSection.replyLine(of: block))
    }

    /// The line the composer's token shows under "Side question" when the
    /// aside is about a reply other than the newest, so the learner can see
    /// which. Nil for the newest reply, where the token alone says enough.
    private var sideQuestionTokenAboutLine: String? {
        guard isSideQuestionMode, let target = sideQuestionTarget, let line = target.line else { return nil }
        guard target.blockID != newestReplyReference?.blockID else { return nil }
        return line
    }

    /// The tutor's question the chat is waiting on, when there is one: the last
    /// paragraph of the newest ordinary reply, if it asks something — or, under
    /// a side question, the question that was open when the aside was asked.
    /// Nil while an ordinary turn runs, since what is open is about to change.
    /// A side question's own reply changes nothing: the waiting question is
    /// stored with the aside, so a follow-up typed while that reply is still
    /// being written goes as a side question too, and joins the lane.
    private var openTutorQuestion: String? {
        guard let last = newestTranscriptSection else { return nil }
        if last.isSideQuestion { return last.openQuestion }
        guard !isTurnInFlight else { return nil }
        guard let block = last.blocks.last, block.userMessage == nil,
              let reply = block.answerMessages.last(where: { message in
                  message.role == .assistant
                      && ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
              }) else { return nil }
        return ChatSideQuestion.openQuestion(
            in: ReviewSessionManager.displayableMessageContent(role: .assistant, content: reply.content) ?? ""
        )
    }

    /// The footer icon on a reply lands here. On the reply the token is
    /// already about, it takes the token off; on any other reply it arms the
    /// composer for an aside about that one and brings the composer to the
    /// front, since the click was up in the transcript.
    private func toggleSideQuestionMode(about reply: ReviewChatReplyReference) {
        if isSideQuestionMode, sideQuestionTarget?.blockID == reply.blockID {
            disarmSideQuestion()
            return
        }
        isSideQuestionMode = true
        sideQuestionTarget = reply
        requestComposerFocus()
    }

    /// The token comes off, from its ×, Escape, Backspace at the start of the
    /// draft, or the armed icon again. The next message goes as usual.
    private func disarmSideQuestion() {
        isSideQuestionMode = false
        sideQuestionTarget = nil
    }

    /// Back from a side question to the tutor's question: answer mode, and the
    /// composer takes focus.
    private func returnToOpenQuestion() {
        disarmSideQuestion()
        requestComposerFocus()
    }

    /// More about the side question, here: the composer takes focus with the
    /// token in place and the lane's reply as what it is about, so the next
    /// Return is another side question and its reply joins the lane. Any open
    /// question stays open underneath. The token is already there after a
    /// side question — it stays armed until the learner goes back to the
    /// question — so this is mostly the focus.
    private func followUpSideQuestion() {
        guard let lane = newestTranscriptSection, lane.isSideQuestion else { return }
        isSideQuestionMode = true
        if let aboutID = lane.aboutBlockID,
           let block = ReviewChatTranscriptBlock.grouping(manager.chatMessages).first(where: { $0.id == aboutID }) {
            sideQuestionTarget = ReviewChatReplyReference(
                blockID: block.id,
                line: ReviewChatTranscriptSection.replyLine(of: block)
            )
        }
        requestComposerFocus()
    }

    /// More details on a reply: the tutor expands it in a lane under it. The
    /// press is stored as a side question the app wrote — the mark, the More
    /// details mark, the reply's first line, and any open question — with the
    /// fixed words "More details" as the learner's line, so it survives a
    /// reopen and syncs like any aside. A reply that already has its lane is
    /// not asked again; the lane opens. A press while a turn is running waits
    /// under it like any queued message.
    private func requestMoreDetails(about reply: ReviewChatReplyReference, existingLaneID: UUID?) {
        if let existingLaneID {
            laneExpansionRequest = ReviewChatLaneExpansionRequest(laneID: existingLaneID, token: UUID())
            return
        }
        let context = ChatSideQuestion.contextContent(
            openQuestion: openTutorQuestion,
            aboutReply: reply.line,
            moreDetails: true
        )
        // The fixed words alone: a picture waiting in the tray belongs to the
        // message the learner is writing, not to this press.
        let content = ChatSideQuestion.moreDetailsQuestion
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(content, contextualContent: context, docAnchor: nil)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(content, contextualContent: context)
        }
    }

    /// The side question leaves the quiz: the aside and every reply it drew
    /// open a new chat as its context, filed under the same Notebook with the
    /// same sources, where the tutor holds nothing back. This chat is left
    /// exactly as it is, its question still open; the token, if armed, is
    /// dropped, since the follow-up is happening elsewhere.
    private func openSideQuestionInNewChat() {
        guard let section = newestTranscriptSection, section.isSideQuestion else { return }
        let turns = section.sideQuestionTurns
        guard !turns.isEmpty else { return }
        disarmSideQuestion()
        let handoff = ChatSideQuestionHandoff(
            chatTitle: manager.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chat" : manager.topic,
            openQuestion: section.openQuestion,
            turns: turns,
            sourceIDs: manager.linkedSourceIDs,
            notebookID: linkedResearchNotebookID
        )
        let request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        if let onOpenNewChatBeside {
            onOpenNewChatBeside(request)
        } else {
            vm.requestChatAboutSideQuestion(request)
        }
    }

    /// The learner lets the open question go. Said in words, so the tutor hears
    /// it the way it would hear the same thing typed. In a quiz's chat the
    /// question is a quiz question, skipped the way Skip Question skips it.
    private func skipOpenQuestion() async {
        disarmSideQuestion()
        if manager.courseQuizOpenQuestionNumber != nil {
            await skipCourseQuizQuestion()
            return
        }
        await sendReviewChatMessage("Let's skip that question and move on.")
    }

    /// Asks this panel's composer to take focus. The docked panes answer the
    /// view model's one request, and so does anything that asks through it; the
    /// page's side chat has a request of its own in its store, so opening it
    /// does not pull focus into the docked chat's field.
    private func requestComposerFocus() {
        if pageSideChat != nil {
            sessionStore.composerFocusRequestID = UUID()
        } else {
            vm.reviewChatFocusRequestID = UUID()
        }
    }

    /// What the empty field says. "Ask anything", ChatGPT's own, for as long
    /// as the chat goes on (product owner, 2026-10-06: "make the app more slick;
    /// kind of like the chatgpt app"); until then it went blank after the
    /// first turn. What the field is for right now — a guess, an aside, a
    /// passage, a walk's card, a mode — says so instead.
    private var chatInputPlaceholder: String {
        if pendingGuessedQuestion != nil {
            return "Your guess first? Return sends both"
        }
        if isSideQuestionMode {
            return openTutorQuestion != nil ? "Ask anything — the quiz waits…" : "Ask an aside about this reply…"
        }
        if let pendingReaderSelection {
            if pendingReaderSelection.reviewHandoff != nil { return "Ask about this exchange…" }
            if pendingReaderSelection.sideQuestionHandoff != nil { return "Go on with the side question…" }
            if pendingReaderSelection.isPictureOnly { return "Ask about this picture…" }
            return "Ask about this passage…"
        }
        // A walk is not a chat: the composer under its card is where a
        // question about that card goes (walkthrough-design.md, "the walk
        // leaves the chat").
        if let playback = manager.walkthroughPlayback {
            let onQuestion = playback.currentStep.flatMap { playback.currentBeat(of: $0) }?.kind == .question
            return onQuestion ? "Answer in your own words, or ask about this card…" : "Ask about this card…"
        }
        if manager.isDeepResearchMode {
            return "Research a question on the web…"
        }
        if manager.currentPromptMode == .shallowRead {
            return "Get the gist of your sources…"
        }
        if manager.currentPromptMode == .deepRead {
            return "Understand your sources in detail…"
        }
        // The Feynman Technique's answers are the learner's explanation.
        if manager.isTeachBackSession {
            return "Explain it in your own words…"
        }
        // ChatGPT's page chat says what it is for, in the field.
        if pageSideChat != nil { return "Work with this page…" }
        if let notebook = linkedResearchNotebook {
            return "Ask about \(notebook.title)…"
        }
        let prompt = defaultInitialPrompt
        return prompt.isEmpty ? "Ask anything" : prompt
    }

    private var reviewTitle: String {
        if reviewSources.count == 1 {
            return reviewSources[0].title
        }
        if !reviewSources.isEmpty {
            return "Selected sources"
        }
        return ""
    }

    /// Where the composer's text is filed while the learner is somewhere else.
    /// Until a chat has been sent it has no session id, so its draft belongs to
    /// the Notebook the New chat button opened it in.
    private var currentDraftScope: ChatDraftScope {
        if let sessionID = manager.currentSessionID {
            return .session(sessionID)
        }
        return .newChat(notebookID: linkedResearchNotebookID)
    }

    /// Puts back whatever was typed into this chat's composer last time. Skipped
    /// while a resume is still pending: the manager is blank for another moment,
    /// so the scope would resolve to the New chat composer rather than the
    /// session about to hydrate, which restores its own draft when it lands.
    @MainActor
    private func restoreDraftForCurrentScope() {
        guard manager.currentSessionID != nil || requestedResumeSessionID == nil else { return }
        let kept = sessionStore.draft(for: currentDraftScope)
        guard !kept.isEmpty else { return }
        // A filed draft keeps a quoted passage as the blockquote it would have
        // been sent as, so it comes back to the composer as a quote again and
        // the words below it as words.
        if let quoted = ChatQuoteDraft.split(userMessage: kept) {
            quotedPassage = quoted.quote
            draft = quoted.body
        } else {
            quotedPassage = ""
            draft = kept
        }
        lastInsertedDefaultPrompt = nil
    }

    /// Files the composer for the chat it belongs to: the words, with any
    /// quoted passage ahead of them as the blockquote the message will carry.
    ///
    /// Only what the learner typed is worth keeping. A machine-inserted opener
    /// is regenerated from the chat's own sources, and storing it would freeze
    /// a stale one into the composer on the way back.
    @MainActor
    private func fileDraft() {
        let typed = draft == lastInsertedDefaultPrompt ? "" : draft
        sessionStore.setDraft(
            ChatQuoteDraft.compose(quote: quotedPassage, body: typed),
            for: currentDraftScope
        )
    }

    /// Empties the composer: the words, the machine-inserted opener it may have
    /// been, and any passage waiting to be quoted.
    @MainActor
    private func clearComposer() {
        draft = ""
        // The next words typed start a new question.
        manager.composerTextChanged("")
        quotedPassage = ""
        lastInsertedDefaultPrompt = nil
        coursePlanningArmed = false
        composer.referencedChats = []
    }

    private func appendDictation(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = text
        } else {
            draft += "\n\(text)"
        }
        lastInsertedDefaultPrompt = nil
    }

    @MainActor
    private func finishManualDictationIntoDraft() async {
        manualDictationResultDestination = .draft
        guard let text = await finishManualDictationTranscription(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manualDictationResultDestination == .draft else {
            if manualDictationResultDestination == .draft {
                manualDictationResultDestination = nil
            }
            return
        }
        appendDictation(text)
        manualDictationResultDestination = nil
    }

    /// The waveform's stop button, and Return while recording. Dictation is
    /// how the learner *says* a message, so the finished transcript goes out
    /// as one — combined with whatever was already typed — rather than landing
    /// in the draft to be sent by a second click. The waveform's X is the way
    /// out of that default: it stops and transcribes into the draft instead,
    /// and while a send is still transcribing the same X reroutes it there
    /// (`finishManualDictationIntoDraft` flips the destination; the send path
    /// sees it changed and stands down). Only while the session is still being
    /// set up does a send fall back to the draft on its own, so the words are
    /// not lost.
    @MainActor
    private func finishManualDictationAndSend() async {
        guard canSubmitComposer else {
            await finishManualDictationIntoDraft()
            return
        }
        await submitComposer()
    }

    @MainActor
    /// `asSideQuestion` is ⌥Return: the draft goes as a side question whether or
    /// not the token is in the field. Return sends what the token says.
    private func submitComposer(asSideQuestion: Bool = false) async {
        // Think first: while a question waits, what is in the field is the
        // learner's guess at its answer, and Return sends the two together.
        if pendingGuessedQuestion != nil {
            var guessText = draft
            // A guess said rather than typed goes once it is transcribed.
            if isManualDictationPending {
                manualDictationResultDestination = .send
                if let transcript = await finishManualDictationTranscription(),
                   manualDictationResultDestination == .send {
                    guessText = combinedComposerText(draft: guessText, transcript: transcript)
                }
            }
            clearComposer()
            manualDictationResultDestination = nil
            await sendPendingGuessedQuestion(guess: ThinkFirst.take(guessText))
            return
        }
        guard canSubmitComposer else { return }
        // Read before anything below clears the composer.
        let plansCourse = coursePlanningArmed

        var answer = draft
        var readerContext: String?
        if isManualDictationPending {
            manualDictationResultDestination = .send
            guard let transcript = await finishManualDictationTranscription(),
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  manualDictationResultDestination == .send else {
                if manualDictationResultDestination == .send {
                    manualDictationResultDestination = nil
                }
                return
            }
            answer = combinedComposerText(draft: answer, transcript: transcript)
        }

        // `/end` stays a command when a passage is waiting to be quoted: the
        // command is what was typed, and the quote is only folded in for a
        // message that is actually going to the tutor.
        let typedTrimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = ChatQuoteDraft.compose(quote: quotedPassage, body: answer)

        // The anchor leaves with the message, not with the click that opened
        // Chat: a passage the learner opened Chat on and then said nothing about
        // is not a conversation, and must not leave a link behind on the doc.
        var docAnchor: ChatDocAnchor?
        let selection = pendingReaderSelection
        if let selection {
            let contextBlock = readerSelectionContextBlock(for: selection)
            if !contextBlock.isEmpty {
                readerContext = contextBlock
            }
            docAnchor = selection.docAnchor
            pendingReaderSelection = nil
        }
        // A page's side chat is always about its page. A chat that quotes no
        // passage links to the page as a whole on its first send, as one that
        // does links to its passage, so the page's Discussion and
        // `list_doc_chats` list it (docs/pages-side-chat-design.md).
        if docAnchor == nil, let card = pageSideChat, manager.currentSessionID == nil {
            docAnchor = card.page.wholePageAnchor
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture alone is a message: "what is this?" is implied.
        let hasImages = !manager.pendingImages.isEmpty
        guard !trimmed.isEmpty || hasImages else { return }

        // Intercept `/` slash commands (settings + quick actions) before anything reaches
        // the tutor. Text that starts with `/` but isn't a known command falls through and
        // is sent as a normal message. A message with a picture attached is never a
        // command: the picture is what the learner is sending.
        if !hasImages, let parsed = ReviewSlashCommandParser.parse(typedTrimmed, commands: slashCommands)
            ?? ReviewSlashCommandParser.parseSkillInvocation(typedTrimmed, commands: slashCommands) {
            // The words go; a quoted passage waits for the message it belongs to.
            draft = ""
            lastInsertedDefaultPrompt = nil
            manualDictationResultDestination = nil
            slashSelectionIndex = 0
            await runSlashCommand(parsed.command, argument: parsed.argument)
            return
        }

        // Chats pointed at with `@` go with this message: their transcripts
        // ride beside it as reference material, and their chips leave the field.
        let referencedChats = composer.referencedChats
        composer.referencedChats = []
        clearComposer()
        manualDictationResultDestination = nil
        if let chatContext = await chatMentionContext(for: referencedChats) {
            readerContext = [readerContext, chatContext].compactMap { $0 }.joined(separator: "\n\n")
        }

        let send = ComposedChatSend(
            text: trimmed,
            typedText: typedTrimmed,
            readerContext: readerContext,
            docAnchor: docAnchor,
            selection: selection,
            plansCourse: plansCourse
        )
        // Think first: a question in a notebook's chat waits for the
        // learner's guess when the notebook's level asks for one.
        if !asSideQuestion, asksForGuess(before: send) {
            pendingGuessedQuestion = send
            requestComposerFocus()
            return
        }
        await dispatchComposerSend(send, asSideQuestion: asSideQuestion, guess: nil)
    }

    /// What a send carries once the composer has given it up: the words,
    /// the passage it quoted and where it came from, and whether it plans a
    /// course. The rest of the send reads it, now or after a guess.
    private struct ComposedChatSend {
        let text: String
        /// What was typed, before a quoted passage was folded in.
        let typedText: String
        var readerContext: String?
        let docAnchor: ChatDocAnchor?
        let selection: ReaderSelectionExplanationRequest?
        let plansCourse: Bool
    }

    /// Whether Think first asks for a guess before this message: a question,
    /// in a notebook's chat whose level is Also Chat, sent as an ordinary
    /// turn of an ordinary chat — no aside, plugin, course plan, walk, review
    /// or research.
    private func asksForGuess(before send: ComposedChatSend) -> Bool {
        guard let notebookID = linkedResearchNotebook?.id,
              ThinkFirst.asks(.chat, notebookID: notebookID),
              ChatGuess.isQuestion(send.typedText),
              !send.plansCourse,
              !isSideQuestionMode,
              [.assistant, .shallowRead, .deepRead].contains(manager.currentPromptMode),
              manager.walkthroughPlayback == nil,
              !manager.isMemoryReviewSession,
              ChatPluginRequest.Mention.first(in: send.text, plugins: chatPlugins) == nil else { return false }
        return true
    }

    /// The guess given (Return) or skipped (the token's ×, Escape, or an
    /// empty field): the held question goes now, with the guess beside it
    /// when there is one.
    @MainActor
    private func sendPendingGuessedQuestion(guess: String?) async {
        guard let send = pendingGuessedQuestion else { return }
        pendingGuessedQuestion = nil
        ThinkFirstTally.record(.chat, answered: guess != nil)
        await dispatchComposerSend(send, asSideQuestion: false, guess: guess)
    }

    /// The send itself: the plugin a message mentions, a side question's
    /// mark or the learner's guess, a walk's card, the marks above them, and
    /// the message, sent now or queued under a reply still being written.
    @MainActor
    private func dispatchComposerSend(_ send: ComposedChatSend, asSideQuestion: Bool, guess: String?) async {
        let trimmed = send.text
        var readerContext = send.readerContext
        let docAnchor = send.docAnchor
        let selection = send.selection
        let plansCourse = send.plansCourse

        // `@slack do xyz`: a message that mentions a connected plugin is a
        // question for that service. The learner's words go as typed, mention
        // included; the plugin rides beside them as a mark the model reads
        // as "answer this from Slack, live" (`ChatPluginRequest`). A mention
        // with nothing else asks the plugin's default question.
        var messageText = trimmed
        let mention = ChatPluginRequest.Mention.first(in: trimmed, plugins: chatPlugins)
        if let mention, ChatPluginRequest.Mention.removing(mention.range, from: trimmed).isEmpty {
            messageText = mention.plugin.defaultRequest(repository: linkedResearchNotebook?.repository)
        }

        // A side question carries its mark beside the message, with the reply
        // it is about and the tutor's open question, if any, so a reopened chat
        // still knows what it was about and what was waiting. Once one has
        // gone, the next message is assumed to be a follow-up about the same
        // reply: the token stays until the learner answers or skips the
        // question, or takes it off. ⌥Return sends one the same way, about the
        // newest reply when none is armed.
        let openQuestion = openTutorQuestion
        if (asSideQuestion || isSideQuestionMode), sideQuestionTarget == nil {
            sideQuestionTarget = newestReplyReference
        }
        // A chat with no reply yet has nothing to ask beside: the message
        // goes as usual.
        let sendsSideQuestion = (asSideQuestion || isSideQuestionMode) && sideQuestionTarget != nil
        isSideQuestionMode = sendsSideQuestion
        if !sendsSideQuestion { sideQuestionTarget = nil }
        // An answer to the newest walkthrough step's question carries the
        // grading brief, so the tutor's reply is the grade (walkthrough-
        // design.md). A side question beside the step is not an answer.
        // Asked on a card the learner went back to: the message belongs to
        // that card, and the tutor reads the card's words above it.
        await manager.bringWalkthroughCardIntoChat()
        if !sendsSideQuestion, let grading = manager.takeWalkthroughAnswerContext() {
            readerContext = [readerContext, grading].compactMap { $0 }.joined(separator: "\n\n")
        }
        // A side question's mark, or Think first's guess, which never goes
        // with an aside (`ChatGuess`).
        let baseContext: String?
        if sendsSideQuestion {
            baseContext = ChatSideQuestion.contextContent(
                openQuestion: openQuestion,
                aboutReply: sideQuestionTarget?.line,
                referenceContext: readerContext
            )
        } else if let guess {
            baseContext = ChatGuess.contextContent(guess: guess, referenceContext: readerContext)
        } else {
            baseContext = readerContext
        }
        // The plugin mark goes first; the request builder reads it off and
        // hands what is under it to the side-question and reference parsing.
        let pluginContext = mention.map {
            ChatPluginRequest.contextContent(for: $0.plugin, referenceContext: baseContext)
        } ?? baseContext
        // Generate's chat: the course-planning instructions go on top, the
        // way a skill's do, so every later turn re-reads them.
        let messageContext = plansCourse
            ? ChatSkillRequest.contextContent(for: CoursePlanningChat.skill, referenceContext: pluginContext)
            : pluginContext
        // The pictures leave with the text, as image lines the bubble draws
        // and the turn sends as image parts; the tray empties here.
        let content = manager.outgoingMessageContent(text: messageText)
        if manager.queuesSendsNow {
            // A reply is still being written: the message waits under it and
            // goes the moment the turn ends, the way a follow-up typed into
            // Claude mid-answer does. Nothing here blocks the learner.
            if let queued = manager.enqueueFollowUp(content, contextualContent: messageContext, docAnchor: docAnchor),
               let selection {
                queuedReaderSelections[queued.id] = selection
            }
            // Only acts when nothing is running to send it after — the last
            // turn failed and this new message is the learner moving on.
            await manager.resumeQueuedFollowUps()
            return
        }
        await sendReviewChatMessage(content, contextualContent: messageContext, docAnchor: docAnchor)
        // The doc that handed over this passage is usually open beside the chat.
        // Tell it a conversation now hangs off that passage, so its Discussion
        // sidebar is right without waiting for the doc to be reopened.
        if docAnchor != nil { vm.artifactChatLinksRevision = UUID() }
    }

    // MARK: - Slash commands

    @MainActor
    private func acceptSlashSuggestion(_ suggestion: ReviewSlashSuggestion) {
        slashSelectionIndex = 0
        // A library row is accepted by identity: two sources can share a title,
        // so the id it carries runs the command and the composer is simply cleared.
        if let picked = suggestion.reference {
            draft = ""
            lastInsertedDefaultPrompt = nil
            Task { await runSlashReference(picked.command, reference: picked.reference) }
            return
        }
        // Something an `@` found: the `@` and its query leave the draft, the
        // rest of what was typed stays, and the item comes in by its own path.
        if let item = suggestion.libraryItem {
            draft = suggestion.completionText
            lastInsertedDefaultPrompt = nil
            Task { await bringMentionIntoChat(item) }
            requestComposerFocus()
            return
        }
        draft = suggestion.completionText
        if suggestion.runsImmediately {
            Task { await submitComposer() }
        }
    }

    /// Brings what an `@` found into this chat, each kind by the path that
    /// already brings it in: a source as `/source` adds it, a Page or a Site as
    /// `/page` and `/site` attach them, a notebook's sources as a dropped
    /// collection adds its sources. A chat waits above the field as a chip;
    /// the send carries its transcript (`chatMentionContext`).
    @MainActor
    private func bringMentionIntoChat(_ item: ChatMention.Item) async {
        switch item.kind {
        case .source:
            await addSourceTokensToChatContext([item.reference])
        case .page, .site:
            await addDocToChatContext(item.reference)
        case .notebook:
            guard let notebook = vm.notebooks.first(where: { $0.id == item.reference }) else { return }
            let sourceIDs = notebook.approvedSourceIDs
            guard !sourceIDs.isEmpty else {
                vm.showToast("\(notebook.title) has no sources yet.")
                return
            }
            await addSourceIDsToChatContext(sourceIDs)
        case .chat:
            guard !composer.referencedChats.contains(where: { $0.reference == item.reference }) else { return }
            composer.referencedChats.append(item)
        }
    }

    /// The reference material for the chats the learner pointed at with `@`:
    /// each one's transcript, read from storage as the message goes, so it
    /// is the chat as it stands now. Nil when none was pointed at.
    @MainActor
    private func chatMentionContext(for chats: [ChatMention.Item]) async -> String? {
        guard !chats.isEmpty else { return nil }
        var blocks: [String] = []
        for chat in chats {
            let exchanges: [ReviewExchangeRecord]
            do {
                exchanges = try await vm.storage.loadReviewSessionExchanges(sessionID: chat.reference)
            } catch {
                vm.errorMessage = "Could not read \(chat.title): \(error.localizedDescription)"
                continue
            }
            var turns: [(speaker: String, text: String)] = []
            for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
                if let opening = ReviewSessionManager.displayableMessageContent(role: .assistant, content: exchange.question) {
                    turns.append(("ForeverLM", opening))
                }
                if let answer = exchange.userAnswer {
                    turns.append(("Learner", answer))
                }
                if let reply = exchange.evaluation.flatMap({
                    ReviewSessionManager.displayableMessageContent(role: .assistant, content: $0)
                }) {
                    turns.append(("ForeverLM", reply))
                }
            }
            blocks.append(ChatMention.chatReferenceContext(title: chat.title, turns: turns))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// What an `@` query finds: sources through the same index and ranking
    /// as `/source`; Pages and Sites over the lists `/page` and `/site` offer;
    /// the learner's chats (not this one, nor a hidden one or a shared link)
    /// and notebooks by title. Each kind newest first among equal matches.
    @MainActor
    private func resolveMentionItems(matching query: String) async -> [ChatMention.Item] {
        guard !query.isEmpty else { return [] }
        var items: [ChatMention.Item] = []

        let index = await vm.artifactSourcePickerIndex()
        let ranked = await Task.detached(priority: .userInitiated) {
            index.rows(matching: query)
        }.value
        items += ranked.prefix(ChatMention.rowsPerTab).map { row in
            ChatMention.Item(kind: .source, reference: row.id, title: row.title, subtitle: row.subtitle)
        }

        for (kind, section) in [(ChatMention.Kind.page, ArtifactSection.docs), (.site, .sites)] {
            let artifacts = slashArtifacts(in: section).sorted { $0.updatedAt > $1.updatedAt }
            items += ChatMention.ranked(artifacts, query: query, title: \.title)
                .prefix(ChatMention.rowsPerTab)
                .map { artifact in
                    ChatMention.Item(
                        kind: kind,
                        reference: artifact.id,
                        title: artifact.title.isEmpty ? "Untitled" : artifact.title,
                        subtitle: Self.slashArtifactSubtitle(for: artifact, section: section)
                    )
                }
        }

        let chats = vm.reviewSessionLinks.filter { record in
            record.id != manager.currentSessionID && !record.isHidden && !record.isExternalLink
                && !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        items += ChatMention.ranked(chats, query: query, title: \.title)
            .prefix(ChatMention.rowsPerTab)
            .map { record in
                let notebook = record.goalID.flatMap { id in vm.notebooks.first { $0.id == id }?.title }
                let started = record.createdAt.formatted(.relative(presentation: .named))
                return ChatMention.Item(
                    kind: .chat,
                    reference: record.id,
                    title: record.title,
                    subtitle: notebook.map { "\($0) · \(started)" } ?? started
                )
            }

        let notebooks = vm.notebooks.sorted { $0.updatedAt > $1.updatedAt }
        items += ChatMention.ranked(notebooks, query: query, title: \.title)
            .prefix(ChatMention.rowsPerTab)
            .map { notebook in
                let count = notebook.approvedSourceIDs.count
                return ChatMention.Item(
                    kind: .notebook,
                    reference: notebook.id,
                    title: notebook.title,
                    subtitle: count == 1 ? "1 source" : "\(count) sources"
                )
            }
        return items
    }

    /// Runs a `/source`, `/doc` or `/site` command on the row the learner
    /// picked from the popup: a source token (`source:<id>` or `book:<id>`) or
    /// a Doc or Site id. A Site is an artifact record like a Doc — a linked
    /// page or a published Markdown doc — so both attach the same way.
    @MainActor
    private func runSlashReference(_ command: ReviewSlashCommand, reference: String) async {
        switch command.kind {
        case .source:
            await addSourceTokensToChatContext([reference])
        case .doc, .site:
            await addDocToChatContext(reference)
        default:
            break
        }
    }

    /// Adds sources named by picker tokens: a chapter or ordinary source by id,
    /// `book:<id>` for a whole book. The `source:` prefix the popup rows carry
    /// is accepted too, so one resolver serves the popup and the picker sheet.
    @MainActor
    private func addSourceTokensToChatContext(_ tokens: [String]) async {
        let ids = ReviewSlashCommandParser.sourceIDs(fromTokens: tokens) { bookID in
            vm.bookChapterArticlesInOrder(for: bookID).map(\.id)
        }
        guard !ids.isEmpty else { return }
        await addSourceIDsToChatContext(ids)
    }

    /// Rows for the `/source`, `/doc` and `/site` popups. Sources go through
    /// the same search as the Docs source picker, so the two agree on what a
    /// query finds and in what order: the title that is the query first, then
    /// titles that start with it, which matters because eight rows is all the
    /// popup shows. Docs and Sites are
    /// few, so they are matched here, each command over its own section — the
    /// split the rail draws (`StudioViewModel.section(of:)`), so `/doc` never
    /// offers a Codex site and `/site` never a draft.
    @MainActor
    private func resolveSlashLiveArguments(
        for command: ReviewSlashCommand,
        query: String
    ) async -> [ReviewSlashCommand.Argument] {
        switch command.kind {
        case .source:
            guard !query.isEmpty else { return [] }
            let index = await vm.artifactSourcePickerIndex()
            let ranked = await Task.detached(priority: .userInitiated) {
                index.rows(matching: query)
            }.value
            return ranked.prefix(Self.slashPopupRowLimit).map { row in
                ReviewSlashCommand.Argument(
                    value: row.title,
                    display: row.subtitle,
                    reference: row.id
                )
            }

        case .doc, .site:
            let folded = StudioViewModel.foldedSidebarSearchString(query)
            let terms = folded.split(separator: " ").map(String.init)
            return slashArtifacts(in: command.kind == .site ? .sites : .docs)
                .filter { artifact in
                    guard !terms.isEmpty else { return true }
                    let title = StudioViewModel.foldedSidebarSearchString(artifact.title)
                    return terms.allSatisfy { title.contains($0) }
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.slashPopupRowLimit)
                .map { artifact in
                    ReviewSlashCommand.Argument(
                        value: artifact.title.isEmpty ? "Untitled" : artifact.title,
                        display: Self.slashArtifactSubtitle(for: artifact, section: vm.section(of: artifact)),
                        reference: artifact.id
                    )
                }

        default:
            return []
        }
    }

    private static let slashPopupRowLimit = 8

    /// The records one section's command offers. A member's draft of a team
    /// Doc carries the team copy's title; listing both would be one doc twice.
    /// The draft is added from its own ⋯ menu while it is open. An archived
    /// or a hidden record is off this list as it is off the pane's; the
    /// pane's Archived and Hidden filters are where each is found again.
    @MainActor
    private func slashArtifacts(in section: ArtifactSection) -> [ArtifactRecord] {
        vm.artifacts.filter {
            !TeamContentIdentity.isDraftArtifactID($0.id) && !$0.isArchived && !$0.isHidden
                && !vm.isAudioOverview($0)
                && vm.section(of: $0) == section
        }
    }

    private static func slashArtifactSubtitle(for artifact: ArtifactRecord, section: ArtifactSection) -> String {
        let edited = artifact.updatedAt.formatted(.relative(presentation: .named))
        // A linked page is named as one wherever a doc row appears, so the
        // picker never offers it as if it were a doc the chat could edit; an
        // animation is named as one rather than as the site it is hosted as.
        if artifact.isLinked { return "\(artifact.kindLabel ?? "Linked page") · updated \(edited)" }
        // A Markdown doc in Sites is there because it has a page on foreverlm.com.
        if section == .sites { return "Published page · edited \(edited)" }
        return artifact.isDraft ? "Draft · edited \(edited)" : "Page · edited \(edited)"
    }

    /// Escape over the popup. A `/` draft is only the command, so it goes;
    /// an `@` takes back just itself and what was typed after it, leaving the
    /// rest of the message.
    @MainActor
    private func dismissSlashSuggestions() {
        draft = draft.hasPrefix("/") ? "" : ChatMention.removingPending(from: draft)
        slashSelectionIndex = 0
    }

    @MainActor
    private func runSlashCommand(_ command: ReviewSlashCommand, argument: String?) async {
        switch command.kind {
        case .goal:
            let topic = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt: String
            if let topic, !topic.isEmpty {
                prompt = "I want to set a learning goal about \(topic). Help me settle on the deadline, find sources for it in my library, and plan a schedule."
            } else {
                prompt = Self.setGoalPrompt
            }
            await sendReviewChatMessage(prompt)

        case .source:
            // The popup handles a query that finds something. Submitting past
            // it — a bare `/source`, or a search that matched nothing — opens the
            // Docs source picker seeded with the text, so the learner can
            // browse by type and chapter and add several at once.
            slashSourcePickerRequest = SlashSourcePickerRequest(
                seed: argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )

        case .doc, .site:
            let section: ArtifactSection = command.kind == .site ? .sites : .docs
            let title = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if slashArtifacts(in: section).isEmpty {
                vm.showToast("You have no \(section.title) yet.")
            } else if title.isEmpty {
                // Return on a bare `/doc` or `/site` before the recent list had arrived.
                draft = "/\(command.name) "
            } else {
                vm.showToast("No \(section.noun.capitalized) matches “\(title)”. Pick one from the /\(command.name) suggestions.")
            }

        case .sitePrompt:
            // The tutor writes the prompt from the conversation and its source
            // catalog; the Notebook named is the one this chat is filed under or
            // works in, so the pasted prompt files the Site in the same place.
            let notebookTitle = (linkedResearchNotebook
                ?? vm.activeNotebookId.flatMap { id in vm.notebooks.first { $0.id == id } })?.title
            await sendReviewChatMessage(
                ReviewSlashCommandParser.sitePromptRequest(focus: argument, notebookTitle: notebookTitle)
            )

        case .animate:
            // The chat draws the animation itself and saves it with
            // save_animation linked to this chat's sources; what to animate
            // is the text after the command.
            await sendReviewChatMessage(ReviewSlashCommandParser.animateRequest(focus: argument))

        case .video:
            // Opens the Videos composer with the concept typed after the
            // command. A chat reading exactly one paper or article grounds the
            // film on it, and stands in for the concept when none was typed;
            // the price is asked in the composer, never here.
            let concept = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let grounding = reviewSources.filter {
                ExplainerVideoGeneratorService.groundingSourceTypes.contains($0.sourceType)
                    && !GeneratedExplainer.isSpokenScriptURL($0.url)
            }
            let source = grounding.count == 1 ? grounding.first : nil
            vm.openVideosInReader()
            vm.explainerVideoComposeRequest = ExplainerVideoComposeRequest(
                concept: concept.isEmpty
                    ? source.map { GeneratedExplainerVideo.concept(forSourceTitled: vm.displayTitle(for: $0)) }
                    : concept,
                sourceID: source?.id
            )

        case .course:
            // The planning chat Generate opens, started from here: the
            // learner's topic goes as "I want to make a course about …" with
            // the course-planning instructions beside it.
            guard let context = ChatSkillRequest.contextContent(for: CoursePlanningChat.skill) else { return }
            await sendReviewChatMessage(
                CoursePlanningChat.request(topic: argument ?? ""),
                contextualContent: context
            )

        case .today:
            // What is on the calendar right now, which is the day's question
            // rather than the Schedule's. Planning a day is /plan.
            await sendReviewChatMessage(
                "Read today's calendar and tell me what I am in now and what it is for, "
                + "and what is still ahead today."
            )

        case .plan:
            // The day on the calendar. The conversation reads the day, the
            // Goals and the recent logs before it asks anything, and it writes
            // the whole day once it is agreed rather than an event at a time.
            await sendReviewChatMessage(
                ReviewSlashCommandParser.planDayRequest(argument)
            )

        case .review:
            guard !manager.isSearching, !manager.isGenerating else {
                vm.showToast("Wait for the current response before starting a review.")
                return
            }
            if !reviewSources.isEmpty {
                await startRequestedReviewChat()
                return
            }
            if let notebook = linkedResearchNotebook ?? idleSuggestedReviewNotebook {
                await startNotebookReviewFromIdle(notebook)
                return
            }
            vm.showToast("Add sources or choose a notebook before starting a review.")

        case .notebook:
            guard let argument, !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                vm.showSpaceAll()
                return
            }
            let matches = vm.notebooks.filter {
                $0.title.compare(argument, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard matches.count == 1, let notebook = matches.first else {
                vm.showToast(matches.isEmpty
                    ? "Notebook not found. Choose one from the /notebook suggestions."
                    : "More than one notebook has that name. Rename one before switching.")
                return
            }
            // `/notebook` chooses the active Notebook explicitly, then opens
            // the notebook in this window with a New chat in it.
            vm.activeNotebookId = notebook.id
            let openNotebook = { vm.openNotebook(notebook.id, startsNotebookChat: false) }
            if let windowState { vm.inWindow(windowState, openNotebook) } else { openNotebook() }
            vm.requestBlankReviewChat(notebookID: notebook.id)

        case .new:
            if let windowState {
                vm.inWindow(windowState) { vm.requestNewChat() }
            } else {
                vm.requestNewChat()
            }
            clearComposer()

        case .model:
            guard let argument, !argument.isEmpty else {
                vm.showToast("Usage: /model <model-id>")
                return
            }
            let provider = KeychainService.resolvedProvider(for: .chat)
            KeychainService.setTaskProvider(provider, for: .chat)
            KeychainService.setTaskModel(argument, for: .chat)
            vm.showToast("Chat model set to \(argument).")

        case .settings:
            if let argument, ReviewSlashCommandParser.namesPlugins(argument) {
                PluginsPlace.requestOpen()
            } else {
                let pane = argument.flatMap(ReviewSlashCommandParser.parseSettingsPane)
                NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
            }

        case .end:
            await manager.completeSession()
            await refreshAfterReviewChatTurn()

        case .help:
            // Re-open the popup with the full command list.
            draft = "/"

        case .skill:
            // The learner's words go as typed, command included, so the
            // transcript shows which skill answered; the skill's instructions,
            // as they stand now, ride beside them (`ChatSkillRequest`).
            guard let skill = SkillLibrary.shared.skills.skill(named: command.name),
                  let context = ChatSkillRequest.contextContent(
                      for: ChatSkillRequest.Skill(name: skill.name, instructions: skill.instructions)
                  ) else {
                // No Settings pane lists skills; the composer does.
                vm.showToast("The skill /\(command.name) is gone. Type / or $ to see the skills you have.")
                return
            }
            let request = argument.map { "/\(skill.name) \($0)" } ?? "/\(skill.name)"
            await sendReviewChatMessage(request, contextualContent: context)

        case .rename:
            guard let record = openChatRecord, canRenameChat else {
                vm.showToast(manager.currentSessionID == nil
                    ? "A new chat takes its name from its first message."
                    : "This chat can't be renamed here.")
                return
            }
            let title = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                // No name typed: the title opens for editing, as a click on it does.
                beginChatTitleRename()
            } else if title != record.title {
                await vm.renameReviewSession(record.id, title: title)
            }

        case .pin:
            guard let record = openChatRecord, !MemoryReviewSession.isMemorySession(record.id) else {
                vm.showToast("Send a message first: a new chat has nothing to pin yet.")
                return
            }
            let pinned = !vm.isChatPinned(record.id)
            vm.setChatPinned(record.id, pinned: pinned)
            vm.showToast(pinned ? "Chat pinned" : "Chat unpinned")

        case .hide:
            guard let record = openChatRecord, !MemoryReviewSession.isMemorySession(record.id) else {
                vm.showToast("Send a message first: a new chat has nothing to hide yet.")
                return
            }
            await vm.setReviewSessionHidden(record.id, hidden: !record.isHidden)
            vm.showToast(record.isHidden ? "Chat shown in Chats again" : "Chat hidden from Chats")

        case .fork:
            guard manager.currentSessionID != nil, !manager.chatMessages.isEmpty else {
                vm.showToast("Send a message first: there is nothing to branch yet.")
                return
            }
            // Branch in New Chat over the whole thread: the reply ⋯'s Branch,
            // from the newest saved turn.
            forkConversation(through: manager.chatMessages)

        case .reasoning:
            await setChatReasoning(argument)
        }
    }

    /// `/reasoning <effort>`: the chat's effort, as the model chip's Effort
    /// submenu sets it, and the effort later chats start on. A bare
    /// `/reasoning` offers the efforts; one the model does not take is
    /// refused with the ones it does.
    @MainActor
    private func setChatReasoning(_ argument: String?) async {
        let offered = await Task.detached(priority: .userInitiated) {
            let selection = KeychainService.resolvedSelection(for: .chat)
            return AIRequestOptionSupport.supportedEfforts(provider: selection.provider, model: selection.model)
        }.value
        guard !offered.isEmpty else {
            vm.showToast("This chat's model has no reasoning effort to set.")
            return
        }
        guard let argument, !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = "/reasoning "
            return
        }
        let names = offered.map(\.displayName).joined(separator: ", ")
        guard let effort = ReviewSlashCommandParser.effort(named: argument) else {
            vm.showToast("Reasoning is one of: \(names).")
            return
        }
        guard offered.contains(effort) else {
            vm.showToast("This model takes \(names).")
            return
        }
        KeychainService.setTaskEffort(effort, for: .chat)
        KeychainService.chosenChatEffort = effort
        vm.showToast("Reasoning: \(effort.displayName)")
    }

    @MainActor
    private func finishManualDictationTranscription() async -> String? {
        if let task = manualDictationTranscriptionTask {
            let text = await task.value
            manualDictationTranscriptionTask = nil
            return text
        }

        guard dictation.isRecording else { return nil }
        let task = Task { @MainActor in
            await dictation.stopAndTranscribe()
        }
        manualDictationTranscriptionTask = task
        let text = await task.value
        manualDictationTranscriptionTask = nil
        return text
    }

    private func combinedComposerText(draft: String, transcript: String) -> String {
        let baseDraft = draft == lastInsertedDefaultPrompt ? "" : draft
        let trimmedDraft = baseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return trimmedTranscript }
        guard !trimmedTranscript.isEmpty else { return trimmedDraft }
        return "\(trimmedDraft)\n\(trimmedTranscript)"
    }

    @MainActor
    private func sendReviewChatMessage(
        _ text: String,
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        adoptLiveNotebookSelection()
        // A message sent in a notebook's chat is working in that notebook:
        // the next window opens it, and the home's Recent order leads with it.
        if let notebookID = linkedResearchNotebook?.id {
            vm.noteNotebookWork(notebookID)
            // A kept question typed rather than clicked is asked all the same.
            vm.noteNotebookQuestionAsked(trimmed, notebookID: notebookID)
        }
        let targetManager = manager
        targetManager.beginGenerationPreparation()
        targetManager.beginSendPreparationTrace()
        // Released the moment the turn itself is over, not when this function
        // returns. The post-turn refresh below reloads the article list, the
        // session links and the companion plan — seconds of work the learner
        // never asked about — and holding the lease across it left the working
        // indicator spinning under a reply that had already finished streaming.
        var preparationLeaseHeld = true
        func releasePreparationLease() {
            guard preparationLeaseHeld else { return }
            preparationLeaseHeld = false
            targetManager.endGenerationPreparation()
        }
        defer { releasePreparationLease() }

        // Sending the default opening prompt starts the session without echoing it as a
        // message, so that one branch gets no bubble. Decided up front, since appending
        // the bubble below is itself what would make `chatMessages` non-empty.
        let hasContextualContent = contextualContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let startsAutomaticSession = !hasContextualContent
            && !targetManager.sessionActive
            && targetManager.chatMessages.isEmpty
            && trimmed == defaultInitialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // The bubble goes up before the first await. Everything below — synthesis
        // context, source hydration, session reopen — can take seconds, and a message
        // that isn't on screen by then reads as the send having been dropped.
        if !startsAutomaticSession {
            targetManager.showUserMessage(trimmed, contextualContent: contextualContent)
        }

        guard await syncSynthesisToolContext() else {
            targetManager.discardOptimisticUserMessage(trimmed)
            targetManager.discardSendPreparationTrace()
            return
        }
        targetManager.markSendPreparation("Notebook files")

        // Attached sources are fetched lazily (only when opened in the reader), so a
        // source dropped straight onto the chat — e.g. a YouTube video — would reach
        // the model with no readable text. Hydrate any missing attached sources first.
        await vm.ensureContextSourceContentLoaded { detail in
            targetManager.setSendPreparationDetail(detail)
        }
        targetManager.setSendPreparationDetail(nil)
        targetManager.markSendPreparation("source download")

        if startsAutomaticSession {
            await targetManager.startSession(
                topic: reviewTitle.isEmpty ? trimmed : reviewTitle,
                articles: reviewSources,
                mode: targetManager.currentPromptMode,
                goalID: linkedResearchNotebookID,
                notebookScopeID: linkedResearchNotebookID
            )
        } else {
            await targetManager.sendMessage(
                text,
                topic: reviewTitle,
                articles: reviewSources,
                initialMode: targetManager.currentPromptMode,
                goalID: linkedResearchNotebookID,
                notebookScopeID: linkedResearchNotebookID,
                contextualContent: contextualContent,
                docAnchor: docAnchor
            )
        }

        releasePreparationLease()
        // A first send that never made a session leaves the messages queued
        // behind it with no turn to follow. They go back to the composer, in
        // this pane only: another chat's draft is not theirs.
        if !targetManager.sessionActive, !targetManager.hasGenerationWorkInFlight,
           targetManager === manager {
            returnQueuedFollowUpsToComposer()
        }
        await refreshAfterReviewChatTurn()
    }

    /// Puts every queued message back into the composer, oldest first, ahead
    /// of anything already typed, and restores the passage the first of them
    /// was about if the composer has none.
    @MainActor
    private func returnQueuedFollowUpsToComposer() {
        let returned = manager.takeQueuedFollowUps()
        guard !returned.isEmpty else { return }
        // Newest first: each goes in ahead of the draft, so the oldest ends up
        // at the top, in the order they were sent.
        for item in returned.reversed() {
            returnQueuedFollowUpToComposer(item)
        }
    }

    /// One queued message back into the composer: its words join the draft on
    /// their own line and its passage becomes the pending selection again.
    @MainActor
    private func returnQueuedFollowUpToComposer(_ item: ReviewSessionManager.QueuedFollowUp) {
        manager.removeQueuedFollowUp(item.id)
        let base = draft == lastInsertedDefaultPrompt ? "" : draft
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmedBase.isEmpty ? item.text : "\(item.text)\n\(trimmedBase)"
        lastInsertedDefaultPrompt = nil
        if let selection = queuedReaderSelections.removeValue(forKey: item.id), pendingReaderSelection == nil {
            pendingReaderSelection = selection
        }
        requestComposerFocus()
    }

    @MainActor
    private func refreshAfterReviewChatTurn() async {
        await vm.refreshArticles()
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
        await vm.refreshMemoryCompanionPlan()
    }

    /// A passage selected in one of this transcript's replies, held beside the
    /// composer and drawn above the field as a quote. It is not typed into the
    /// draft: the learner writes only the question, and the send folds the
    /// passage in ahead of it as a blockquote.
    @MainActor
    /// Opens the chat's Browser tab in the pane of the window that holds it.
    private func revealChatBrowserTab() {
        guard let agent = manager.browserAgent as? StudioChatBrowserAgent, agent.hasTab else { return }
        let destination = agent.tabWindowID.flatMap { id in
            StudioWindowRegistry.shared.states.first { $0.id == id }
        }
        vm.activateCenterTab(.browser, in: destination)
        agent.revealTab()
    }

    // MARK: - Words selected in a reply

    /// The bar over a selection in a reply, or the reply's context menu.
    private func handleReplySelection(
        _ action: ChatReplySelectionAction,
        passage: String,
        messageID: UUID,
        anchor: ChatSelectionAnchor?
    ) {
        switch action {
        case .quote:
            quoteIntoDraft(passage)
        case .moreDetails:
            requestMoreDetails(aboutPassage: passage, inReplyContaining: messageID)
        case .sideChat:
            openReplySideChat(aboutPassage: passage, inReplyContaining: messageID, anchor: anchor)
        }
    }

    /// The words under "More details" on a selected passage. Fixed, so the
    /// press reads the same in every chat; the passage above them says what
    /// they are about.
    static let moreDetailsAboutPassage = "Tell me more about this."

    /// More details on a passage: the tutor expands those words. The press
    /// goes as a message the learner could have typed — the passage quoted,
    /// the fixed words under it — so the bubble shows which words were meant
    /// and the reply reads back later. While a tutor question is open, or the
    /// composer is armed as a side question, it goes as an aside about the
    /// reply the words came from, so the question stays open and its answer
    /// is protected; otherwise it moves the conversation on like any
    /// follow-up. A press while a turn is running waits under it like any
    /// queued message. The picture tray is left alone: a picture waiting
    /// there belongs to the message the learner is writing.
    private func requestMoreDetails(aboutPassage passage: String, inReplyContaining messageID: UUID) {
        let content = ChatQuoteDraft.compose(quote: passage, body: Self.moreDetailsAboutPassage)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reply = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
            .first { block in block.answerMessages.contains { $0.id == messageID } }
            .map { ReviewChatReplyReference(blockID: $0.id, line: ReviewChatTranscriptSection.replyLine(of: $0)) }
        let openQuestion = openTutorQuestion
        let asAside = openQuestion != nil || isSideQuestionMode
        let context = asAside
            ? ChatSideQuestion.contextContent(
                openQuestion: openQuestion,
                aboutReply: reply?.line ?? sideQuestionTarget?.line
            )
            : nil
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(content, contextualContent: context, docAnchor: nil)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(content, contextualContent: context)
        }
    }

    /// A side chat opens over the passage: a popover with a field, where the
    /// tutor answers about these words with the reply, the conversation and
    /// the source text this chat has loaded in view (`ChatReplySideChat`).
    /// This chat is left exactly as it is —
    /// nothing is sent here, nothing is saved, no chat is started. The field
    /// takes focus empty: the learner came to ask something, and no model is
    /// spent until they do. It opens on the side of the words with room for
    /// it to grow at this chat's zoom.
    ///
    /// A side chat already open closes first. Only its X closes it otherwise,
    /// so it is often still up when new words are chosen, and one popover
    /// closing while another opens in the same update left none open when the
    /// new words were in another reply; the new one opens on the next turn.
    private func openReplySideChat(
        aboutPassage passage: String,
        inReplyContaining messageID: UUID,
        anchor: ChatSelectionAnchor?
    ) {
        let replacesOpen = replySideChat.map { open in
            closeReplySideChat(open)
            return true
        } ?? false
        let messages = manager.chatMessages
        let replyIndex = messages.firstIndex(where: { $0.id == messageID })
        let replyText = replyIndex.map { index in
            ReviewSessionManager.displayableMessageContent(role: .assistant, content: messages[index].content) ?? ""
        } ?? ""
        // The exchange before the reply the words are in: only what the
        // learner and tutor said, as the transcript shows it.
        let earlier = messages.prefix(replyIndex ?? messages.count)
        let recentTurns = earlier.compactMap { message -> ChatSideQuestionHandoff.Turn? in
            guard message.role == .user || message.role == .assistant,
                  let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .init(speaker: message.role == .user ? .learner : .tutor, text: text)
        }
        let context = ChatReplySideChatContext(
            passage: passage,
            replyText: replyText,
            chatTitle: manager.topic,
            recentTurns: recentTurns,
            openQuestion: openTutorQuestion,
            sourceText: manager.loadedSourceText
        )
        let model = ChatReplySideChatModel(
            messageID: messageID,
            anchor: anchor?.rect,
            placement: ChatReplySideChatPlacement.choose(
                room: anchor?.screenRoom,
                fullHeight: ReviewChatSideChatPopover.fullHeight(zoom: uiZoomScale)
            ),
            context: context,
            backend: LiveChatReplySideChatBackend(aiService: AIService())
        )
        if replacesOpen {
            DispatchQueue.main.async { replySideChat = model }
        } else {
            replySideChat = model
        }
    }

    /// The popover closed, by the learner or by another taking its place. An
    /// answer still being written stops; the exchange is gone with the view.
    private func closeReplySideChat(_ model: ChatReplySideChatModel) {
        guard replySideChat === model else { return }
        model.cancel()
        replySideChat = nil
    }

    /// The side chat leaves for a new chat beside this one, with this chat's
    /// sources, so the question can be gone into from the same material. An
    /// exchange travels as a side question does, its first line carrying the
    /// passage as a quote; a side chat with nothing said yet hands the passage
    /// over the way a Reader selection arrives. This chat is left exactly as
    /// it is. A pane with no neighbour to hand to — the comparison pane, the
    /// pop-out window — sends it to the primary Chat instead.
    private func continueReplySideChatInNewChat(_ model: ChatReplySideChatModel) {
        let topic = manager.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? reviewSources.map(\.id) : manager.linkedSourceIDs
        let request: ReaderSelectionExplanationRequest
        if let handoff = model.handoff(
            chatTitle: topic,
            openQuestion: model.context.openQuestion,
            sourceIDs: sourceIDs,
            notebookID: linkedResearchNotebookID
        ) {
            request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        } else {
            request = ReaderSelectionExplanationRequest(
                sourceIDs: sourceIDs,
                selectedText: model.context.passage,
                contextTitle: topic.isEmpty
                    ? "A reply in another chat"
                    : "A reply in the chat \u{201C}\(topic)\u{201D}"
            )
        }
        closeReplySideChat(model)
        if let onOpenNewChatBeside {
            onOpenNewChatBeside(request)
        } else if request.sideQuestionHandoff != nil {
            vm.requestChatAboutSideQuestion(request)
        } else {
            vm.requestChatAboutPassage(request)
        }
    }

    private func quoteIntoDraft(_ passage: String) {
        let quoted = ChatQuoteDraft.adding(passage, to: quotedPassage)
        guard quoted != quotedPassage else { return }
        quotedPassage = quoted
        // A machine-inserted opener gives way to the quote; words the learner
        // typed stay, with the caret still after them.
        if draft == lastInsertedDefaultPrompt { draft = "" }
        lastInsertedDefaultPrompt = nil
        fileDraft()
        requestComposerFocus()
    }

    @MainActor
    private func handleReaderSelectionExplanationRequest() async {
        guard let request = vm.readerSelectionExplanationRequest else { return }
        defer { vm.readerSelectionExplanationRequest = nil }

        let contextBlock = readerSelectionContextBlock(for: request)
        guard !contextBlock.isEmpty else { return }

        // A chat still waiting to open here — the window's last chat after a
        // relaunch, a mark's linked chat — is a conversation too: joining the
        // idle composer in front of it left the passage under that chat once
        // it landed. The passage is the later intent, so it goes to a new
        // chat and the open gives way.
        let opensNewChat = sessionStore.readerSelectionOpensNewChat(for: request) || requestedResumeSessionID != nil
        if opensNewChat, request.isReaderSelection || request.sendsAtOnce,
           acceptsGlobalNavigationRequests, vm.reviewChatResumeSessionID != nil {
            vm.reviewChatResumeSessionID = nil
        }

        // What's New and Find directions are research the learner asked for,
        // sent at once: in this pane when it holds nothing yet, otherwise in a
        // fresh chat, so a conversation under way is never turned into the
        // research.
        if request.sendsAtOnce {
            if opensNewChat {
                readsNotebookTicksLive = false
                vm.setContextSources(request.sourceIDs)
                sessionStore.requestNewChat(handingOff: request)
            } else {
                // Its own task: the turn runs for minutes, and this request's
                // handler should not stay open, or hold the request, that long.
                Task { await startResearchUpdate(request) }
            }
            return
        }

        // A passage from the Reader is a new conversation, not a turn of the
        // one on screen — even when that one is about the same paper. The
        // chat that was open stays exactly as it is (a running turn keeps
        // running, parked), and the passage waits under a fresh chat's composer with its source
        // attached, the way a handed-off exchange does. The idle pool is set
        // rather than added to, as every new-chat route does, so the fresh
        // chat starts from this source and not from what an earlier question
        // left staged.
        if request.isReaderSelection, opensNewChat {
            readsNotebookTicksLive = false
            vm.setContextSources(request.sourceIDs)
            sessionStore.requestNewChat(handingOff: request)
            return
        }

        pendingReaderSelection = request
        // The selection's pictures, fetched by the reader, join the tray the
        // way a dropped picture does; the message carries them as image lines.
        for attachment in request.imageAttachments { manager.attachImage(attachment) }

        // A doc hands over a complete grounding: the sources the highlighted
        // passage cites, and only those. Whatever an idle pane was still
        // holding would otherwise be read as part of the answer to a question
        // it has nothing to do with. A conversation already under way keeps
        // everything it has — `clearStagedSources` refuses there.
        if request.artifactID != nil { manager.clearStagedSources() }
        // The doc rides along by identity, so `read_doc` is offered for the
        // rest of it — the excerpt in the message is one section, not the doc.
        if let doc = request.artifactAttachment { manager.addContextDoc(doc) }

        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
    }

    /// The chip's one line for the passage. TeX in a selection is folded into
    /// readable text here only; the request itself keeps the markup, so the
    /// model reads exactly what the learner selected.
    private func readerSelectionPreview(for request: ReaderSelectionExplanationRequest) -> String {
        let selectedText = request.selectedText
            .foldingTeXForPreview()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedText.isEmpty, request.isPictureOnly {
            return request.imageAttachments.count == 1 ? "Selected picture" : "Selected pictures"
        }
        guard !selectedText.isEmpty else { return "Selected passage" }
        if selectedText.count <= 120 {
            return selectedText
        }
        return String(selectedText.prefix(117)) + "…"
    }

    private func readerSelectionContextBlock(for request: ReaderSelectionExplanationRequest) -> String {
        let rawSourceTitle = request.sourceIDs.first.flatMap { vm.articlesById[$0]?.title }
        return request.contextualContent(fallbackTitle: rawSourceTitle)
    }

    /// What's New on a mark (chat-design.md, "What's New"): this chat becomes
    /// a Deep Research chat about the mark's source, the passage and the
    /// research steps go out at once in the learner's name, and the chat links
    /// itself to the mark when that first message is saved.
    ///
    /// It starts the same way from an idle pane as from a fresh one: about the
    /// mark's source alone, and filed under no Notebook, since research into a
    /// passage is not the conversation an idle Notebook composer was waiting for.
    @MainActor
    private func startResearchUpdate(_ request: ReaderSelectionExplanationRequest) async {
        if let search = request.directionSearch {
            await startDirectionSearch(search, request: request)
            return
        }
        guard let research = request.researchUpdate else { return }
        pendingReaderSelection = nil
        linkedResearchNotebookID = windowNotebookForNewChat
        readsNotebookTicksLive = false
        vm.setContextSources(request.sourceIDs)
        manager.clearStagedSources()
        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        manager.setAssistantMode(.deepResearch)
        // Refused while a turn runs, which a pane holding nothing never has.
        guard manager.isDeepResearchMode else { return }
        manager.pendingSourceHighlightLink = research.highlightID
        await sendReviewChatMessage(
            ReaderSelectionExplanationRequest.researchUpdateMessage,
            contextualContent: readerSelectionContextBlock(for: request)
        )
    }

    /// Find directions on a Goal, Notebook or Idea (docs/directions-design.md):
    /// this chat becomes a Deep Research chat with the home's sources in
    /// context, filed beside the home's Notebook when it has one, and the
    /// request goes out at once in the learner's name. The steps arrive as
    /// the chat's first tool call, `find_directions`.
    @MainActor
    private func startDirectionSearch(_ search: DirectionSearchLaunch, request: ReaderSelectionExplanationRequest) async {
        pendingReaderSelection = nil
        linkedResearchNotebookID = search.notebookID.flatMap { vm.notebook(id: $0) != nil ? $0 : nil }
            ?? windowNotebookForNewChat
        readsNotebookTicksLive = false
        vm.setContextSources(request.sourceIDs)
        manager.clearStagedSources()
        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        manager.setAssistantMode(.deepResearch)
        // Refused while a turn runs, which a pane holding nothing never has.
        guard manager.isDeepResearchMode else { return }
        await sendReviewChatMessage(
            search.message,
            contextualContent: request.contextualContent()
        )
    }

    @MainActor
    private func switchSummarizeChatToReview() async {
        clearComposer()
        pendingReaderSelection = nil
        await manager.switchToReviewSession()
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    private var shouldSpeakAssistantResponses: Bool {
        voiceConversationEnabled
    }

    private var latestAssistantMessage: ReviewSessionManager.Message? {
        manager.chatMessages.last(where: { $0.role == .assistant })
    }

    private func handleVoiceConversationModeChange(_ enabled: Bool) {
        if enabled {
            if latestAssistantMessage != nil {
                speakLatestAssistantMessageIfNeeded(force: true)
            } else {
                speakVoiceModePrompt()
            }
        } else {
            dictation.cancelRecording()
            if !preserveCurrentSpeechOnVoiceModeDisable {
                speech.stop()
            }
            preserveCurrentSpeechOnVoiceModeDisable = false
        }
    }

    private func speakVoiceModePrompt() {
        guard manager.chatMessages.isEmpty else { return }
        if !reviewSources.isEmpty {
            let sourceCount = reviewSources.count
            let sourceText = sourceCount == 1 ? "the selected source" : "\(sourceCount) selected sources"
            speech.speak("Voice conversation is on. Say what you want to review, or say start review to begin with \(sourceText).")
        } else {
            speech.speak("Voice conversation is on. Say review today, review tomorrow, review yesterday, or name a source you want to review.")
        }
    }

    private func speakLatestAssistantMessageIfNeeded(force: Bool = false) {
        guard shouldSpeakAssistantResponses,
              !manager.isGenerating,
              !manager.isSearching,
              let message = latestAssistantMessage else { return }
        guard force || lastSpokenAssistantMessageID != message.id else { return }
        speakAssistantMessage(message)
    }

    private func speakAssistantMessage(_ message: ReviewSessionManager.Message) {
        guard message.role == .assistant,
              let content = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }
        lastSpokenAssistantMessageID = message.id
        speech.speak(content, messageID: message.id)
    }

    @MainActor
    private func deleteChatMessage(_ message: ReviewSessionManager.Message) {
        if speech.currentMessageID == message.id {
            speech.stop()
        }
        Task {
            await manager.deleteMessage(message)
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    private func createResearchNotebook(from message: ReviewSessionManager.Message) {
        guard let content = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }

        let title = researchNotebookTitle(for: content)
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? reviewSources.map(\.id) : manager.linkedSourceIDs
        let markdown = """
        # \(title)

        ## Chat Synthesis

        \(content)
        """

        Task {
            guard let notebook = await vm.createNotebookContext(title: title) else { return }
            if let updated = await vm.replaceNotebookSynthesisFromChat(
                notebookID: notebook.id,
                markdown: markdown,
                sourceIDs: sourceIDs
            ) {
                linkedResearchNotebookID = updated.id
            } else {
                linkedResearchNotebookID = notebook.id
            }
        }
    }

    @MainActor
    @discardableResult
    private func syncSynthesisToolContext() async -> Bool {
        guard let notebook = synthesisNotebook else {
            manager.synthesisToolContext = nil
            return true
        }

        let notebookMaterialsMarkdown: String
        do {
            notebookMaterialsMarkdown = try await vm.storage.notebookMaterialContext(notebookID: notebook.id)
        } catch {
            manager.errorMessage = "Could not load the notebook's files. \(error.localizedDescription)"
            return false
        }

        manager.synthesisToolContext = ReviewSessionManager.SynthesisToolContext(
            title: notebook.title,
            markdown: notebook.notes ?? "",
            instructions: notebook.description,
            researchQuestions: notebook.researchQuestions ?? [],
            repository: notebook.linkedRepository,
            notebookMaterialsMarkdown: notebookMaterialsMarkdown
        )
        return true
    }

    private func executeSynthesisToolCall(_ call: ReviewSessionManager.SynthesisToolCall) async {
        guard let notebook = synthesisNotebook else {
            manager.completeSynthesisToolCall(call.id, message: "I do not have a notebook to update yet. Create or link a notebook first.")
            return
        }
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? reviewSources.map(\.id) : manager.linkedSourceIDs
        let updated: LearningGoalRecord?
        switch call.action {
        case .append:
            let currentNotes = notebook.notes ?? ""
            guard !Self.markdownAlreadyContains(call.markdown, in: currentNotes) else {
                manager.completeSynthesisToolCall(call.id, message: "That note is already in \(notebook.title).")
                return
            }
            guard let mergedNotes = await vm.generateNotebookNotesMerge(
                currentNotesMarkdown: currentNotes,
                newInsightMarkdown: call.markdown,
                notebookTitle: notebook.title
            ) else {
                manager.completeSynthesisToolCall(call.id, message: "I tried to update the synthesis, but the app could not merge the note.")
                return
            }
            guard !Self.markdownEquivalent(mergedNotes, currentNotes) else {
                manager.completeSynthesisToolCall(call.id, message: "That note is already in \(notebook.title).")
                return
            }
            updated = await vm.replaceNotebookSynthesisFromChat(
                notebookID: notebook.id,
                markdown: mergedNotes,
                sourceIDs: sourceIDs
            )
        case .replace:
            updated = await vm.replaceNotebookSynthesisFromChat(
                notebookID: notebook.id,
                markdown: call.markdown,
                sourceIDs: sourceIDs
            )
        }

        if let updated {
            linkedResearchNotebookID = updated.id
            await syncSynthesisToolContext()
            let message = call.action == .append
                ? "Merged the note into \(updated.title)."
                : "Updated \(updated.title)."
            manager.completeSynthesisToolCall(call.id, message: message)
        } else {
            manager.completeSynthesisToolCall(call.id, message: "I tried to update the synthesis, but the app could not save it.")
        }
    }

    private static func markdownAlreadyContains(_ addition: String, in notes: String) -> Bool {
        let normalizedAddition = normalizedMarkdownForDuplicateCheck(addition)
        let normalizedNotes = normalizedMarkdownForDuplicateCheck(notes)
        guard !normalizedAddition.isEmpty else { return true }
        if normalizedNotes.contains(normalizedAddition) { return true }

        let additionWithoutHeading = normalizedMarkdownForDuplicateCheck(
            addition
                .split(whereSeparator: \.isNewline)
                .drop(while: { String($0).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") })
                .joined(separator: "\n")
        )
        return !additionWithoutHeading.isEmpty && normalizedNotes.contains(additionWithoutHeading)
    }

    private static func markdownEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalizedMarkdownForDuplicateCheck(lhs) == normalizedMarkdownForDuplicateCheck(rhs)
    }

    private static func normalizedMarkdownForDuplicateCheck(_ markdown: String) -> String {
        markdown
            .lowercased()
            .replacingOccurrences(of: #"(?m)^#+\s*chat insight\s*-\s*.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func researchNotebookTitle(for content: String) -> String {
        if !manager.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manager.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .description
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*` ").union(.whitespacesAndNewlines)) ?? ""
        guard !firstLine.isEmpty else { return "Notebook" }
        return String(firstLine.prefix(90))
    }

    private func speakLatestAssistantMessage() {
        guard let message = latestAssistantMessage else { return }
        speakAssistantMessage(message)
    }

    @MainActor
    private func handleAssistantSpeechFinished(messageID: UUID?) async {
        if voiceConversationEnabled,
           messageID == nil,
           manager.chatMessages.isEmpty,
           !dictation.isRecording,
           !dictation.isTranscribing {
            await startVoiceConversationRecording()
            return
        }

        guard voiceConversationEnabled,
              messageID == latestAssistantMessage?.id,
              !manager.isGenerating,
              !manager.isSearching,
              !dictation.isRecording,
              !dictation.isTranscribing else { return }
        await startVoiceConversationRecording()
    }

    @MainActor
    private func startVoiceConversationRecording() async {
        guard voiceConversationEnabled,
              !dictation.isRecording,
              !dictation.isTranscribing,
              !manager.isGenerating,
              !manager.isSearching else { return }

        await dictation.startRecording(automaticallyStopsAfterSilence: true) {
            Task { @MainActor in
                await finishVoiceConversationRecording()
            }
        }
    }

    @MainActor
    private func finishVoiceConversationRecording() async {
        guard voiceConversationEnabled,
              dictation.isRecording,
              !manager.isGenerating,
              !manager.isSearching else { return }

        guard let transcript = await dictation.stopAndTranscribe() else { return }
        if isVoiceCancelCommand(transcript) {
            voiceConversationEnabled = false
            return
        }

        if await handleVoiceConversationControlCommand(transcript) {
            return
        }

        if !manager.sessionActive, manager.chatMessages.isEmpty {
            let handled = await handleVoiceConversationStartCommand(transcript)
            if handled { return }
        }

        let response = voiceResponseText(from: transcript)
        guard !response.isEmpty else {
            await startVoiceConversationRecording()
            return
        }
        await sendReviewChatMessage(response)
    }

    private func isVoiceCancelCommand(_ transcript: String) -> Bool {
        let cancelPattern = #"(?i)^\s*(cancel|never mind|nevermind|discard)\s*[\.\!\?]*\s*$"#
        return transcript.range(of: cancelPattern, options: .regularExpression) != nil
    }

    @MainActor
    private func handleVoiceConversationControlCommand(_ transcript: String) async -> Bool {
        let command = normalizedVoiceCommand(transcript)
        guard !command.isEmpty else { return false }

        if command == "repeat"
            || command == "repeat that"
            || command == "say that again"
            || command == "one more time" {
            speakLatestAssistantMessageIfNeeded(force: true)
            return true
        }

        if command == "pause"
            || command == "stop listening"
            || command == "stop voice mode"
            || command == "turn off voice mode" {
            voiceConversationEnabled = false
            return true
        }

        if command == "complete review"
            || command == "finish review"
            || command == "end review" {
            guard manager.sessionActive else {
                speech.speak("There is no active review to complete.")
                return true
            }
            await manager.completeSession()
            await refreshAfterReviewChatTurn()
            if manager.errorMessage == nil {
                preserveCurrentSpeechOnVoiceModeDisable = true
                voiceConversationEnabled = false
                speech.speak("Review completed and saved.")
            }
            return true
        }

        return false
    }

    @MainActor
    private func handleVoiceConversationStartCommand(_ transcript: String) async -> Bool {
        let command = normalizedVoiceCommand(transcript)
        guard !command.isEmpty else {
            await startVoiceConversationRecording()
            return true
        }

        let requestedScheduleDate = voiceScheduleDate(from: command)

        if isScheduleListingCommand(command) {
            await loadVoiceScheduleChoices(for: requestedScheduleDate ?? Date())
            speakSchedule()
            return true
        }

        if isReviewCurrentContextCommand(command), !reviewSources.isEmpty {
            await startVoiceReview(with: reviewSources, topic: reviewTitle)
            return true
        }

        if isReviewScheduleCommand(command) {
            let scheduleDate = requestedScheduleDate ?? (voiceScheduleChoices.isEmpty ? Date() : voiceScheduleChoicesDate)
            await loadVoiceScheduleChoices(for: scheduleDate)
            if voiceScheduleChoices.isEmpty {
                speech.speak("There are no scheduled sources for \(voiceScheduleLabel(for: scheduleDate)). Say the name of a source instead.")
                return true
            }
            if voiceScheduleChoices.count == 1 {
                await startVoiceReview(with: articles(for: [voiceScheduleChoices[0]]), topic: voiceScheduleChoices[0].title)
                return true
            }
            if isReviewAllCommand(command) || requestedScheduleDate != nil {
                await startVoiceReview(
                    with: articles(for: voiceScheduleChoices),
                    topic: "\(voiceScheduleLabel(for: scheduleDate).capitalized) scheduled sources"
                )
                return true
            }
            speakSchedule(prefix: "You have \(voiceScheduleChoices.count) sources for \(voiceScheduleLabel(for: scheduleDate)).")
            return true
        }

        if !voiceScheduleChoices.isEmpty,
           let item = matchVoiceScheduleChoice(command) {
            await startVoiceReview(with: articles(for: [item]), topic: item.title)
            return true
        }

        if let article = matchArticle(command) {
            await startVoiceReview(with: [article], topic: article.title)
            return true
        }

        return false
    }

    @MainActor
    private func loadVoiceScheduleChoices(for date: Date) async {
        if vm.learningGoals.isEmpty {
            await vm.loadLearningGoals()
        }
        voiceScheduleChoicesDate = date
        voiceScheduleChoices = scheduledItems(on: date)
    }

    /// The day's plan as the Today card reads it: every deliberate placement,
    /// whichever Goal or Notebook it serves, or none.
    private func scheduledItems(on date: Date) -> [SchedulePlanItem] {
        let calendar = Calendar.current
        return vm.unifiedScheduleDays(containing: date)
            .first { calendar.isDate($0.date, inSameDayAs: date) }?
            .items
            .filter { !$0.isMissingSource } ?? []
    }

    private func speakSchedule(prefix: String? = nil) {
        guard !voiceScheduleChoices.isEmpty else {
            speech.speak("There are no scheduled sources for \(voiceScheduleLabel(for: voiceScheduleChoicesDate)).")
            return
        }

        let list = voiceScheduleChoices.prefix(6).enumerated().map { index, item in
            "Number \(index + 1): \(item.title)"
        }.joined(separator: ". ")
        let extra = voiceScheduleChoices.count > 6 ? " There are \(voiceScheduleChoices.count - 6) more after that." : ""
        let intro = prefix ?? "The scheduled sources for \(voiceScheduleLabel(for: voiceScheduleChoicesDate)) are:"
        speech.speak("\(intro) \(list).\(extra) Say review all, review number one, or say a title.")
    }

    @MainActor
    private func startVoiceReview(with articles: [StudioArticle], topic: String) async {
        let articles = articles.filter { vm.isSourceIncludedInKnowledge($0) }
        guard !articles.isEmpty else {
            speech.speak("I could not find readable sources for that review.")
            return
        }
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            manager.endSession()
        }
        readsNotebookTicksLive = false
        vm.setContextSources(articles.map(\.id))
        clearComposer()
        speech.stop()
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(topic: topic, articles: articles)
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    private func articles(for items: [SchedulePlanItem]) -> [StudioArticle] {
        items.compactMap { item in
            vm.articles.first { $0.id == item.sourceID }
        }
    }

    private func isScheduleListingCommand(_ command: String) -> Bool {
        command.contains("what") && (command.contains("today") || command.contains("tomorrow") || command.contains("yesterday") || command.contains("schedule"))
            || command.contains("list today")
            || command.contains("list tomorrow")
            || command.contains("list yesterday")
            || command.contains("read today")
            || command.contains("read tomorrow")
            || command.contains("read yesterday")
            || command.contains("what do i have")
    }

    private func isReviewScheduleCommand(_ command: String) -> Bool {
        command.contains("review today")
            || command.contains("review tomorrow")
            || command.contains("review yesterday")
            || command.contains("start today")
            || command.contains("start tomorrow")
            || command.contains("start yesterday")
            || command.contains("today s review")
            || command.contains("todays review")
            || command.contains("tomorrow s review")
            || command.contains("tomorrows review")
            || command.contains("yesterday s review")
            || command.contains("yesterdays review")
            || command.contains("today s session")
            || command.contains("todays session")
            || command.contains("tomorrow s session")
            || command.contains("tomorrows session")
            || command.contains("yesterday s session")
            || command.contains("yesterdays session")
            || command.contains("scheduled")
            || isReviewAllCommand(command)
            || command == "start review"
    }

    private func isReviewAllCommand(_ command: String) -> Bool {
        command == "review all"
            || command == "start all"
            || command.contains("all of them")
            || command.contains("everything today")
    }

    private func isReviewCurrentContextCommand(_ command: String) -> Bool {
        command == "start"
            || command == "start review"
            || command == "review this"
            || command == "review these"
            || command == "review selected"
            || command == "review current"
    }

    private func voiceScheduleDate(from command: String) -> Date? {
        let calendar = Calendar.current
        if command.contains("yesterday") || command.contains("yesterdays") || command.contains("yesterday s") {
            return calendar.date(byAdding: .day, value: -1, to: Date())
        }
        if command.contains("tomorrow") || command.contains("tomorrows") || command.contains("tomorrow s") {
            return calendar.date(byAdding: .day, value: 1, to: Date())
        }
        if command.contains("today") || command.contains("todays") || command.contains("today s") {
            return Date()
        }
        return nil
    }

    private func voiceScheduleLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func matchVoiceScheduleChoice(_ command: String) -> SchedulePlanItem? {
        if isReviewAllCommand(command) {
            return nil
        }

        let numberWords = [
            "one": 1, "first": 1,
            "two": 2, "second": 2,
            "three": 3, "third": 3,
            "four": 4, "fourth": 4,
            "five": 5, "fifth": 5,
            "six": 6, "sixth": 6
        ]
        for (word, number) in numberWords where command.contains(word) {
            let index = number - 1
            if voiceScheduleChoices.indices.contains(index) {
                return voiceScheduleChoices[index]
            }
        }

        if let match = voiceScheduleChoices.first(where: { commandMatchesTitle(command, title: $0.title) }) {
            return match
        }
        return nil
    }

    private func matchArticle(_ command: String) -> StudioArticle? {
        vm.articles.first { article in
            commandMatchesTitle(command, title: article.title)
        }
    }

    private func commandMatchesTitle(_ command: String, title: String) -> Bool {
        let normalizedTitle = normalizedVoiceCommand(title)
        guard !normalizedTitle.isEmpty else { return false }
        if command.contains(normalizedTitle) { return true }
        let titleWords = normalizedTitle.split(separator: " ").filter { $0.count > 3 }
        guard titleWords.count >= 2 else { return false }
        let matchedWords = titleWords.filter { command.contains($0) }.count
        return matchedWords >= min(3, titleWords.count)
    }

    private func normalizedVoiceCommand(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func voiceResponseText(from transcript: String) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let submitPattern = #"(?i)[\s,.;:!\?]*(done|submit|send|send it|that's it|that is it|over)\s*[\.\!\?]*\s*$"#
        while let range = result.range(of: submitPattern, options: .regularExpression) {
            result.removeSubrange(range)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    @MainActor
    private func refreshDefaultDraft() {
        guard !manager.sessionActive, manager.chatMessages.isEmpty else {
            if draft == lastInsertedDefaultPrompt {
                draft = ""
            }
            lastInsertedDefaultPrompt = nil
            return
        }

        let prompt = defaultInitialPrompt
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = prompt
            lastInsertedDefaultPrompt = prompt
        }
    }

    private func contextNoun(for type: StudioSourceType) -> (singular: String, plural: String) {
        switch type {
        case .article, .unclassified: return ("article", "articles")
        case .paper: return ("paper", "papers")
        case .podcast: return ("podcast", "podcasts")
        case .book: return ("book", "books")
        case .course: return ("course", "courses")
        case .meeting: return ("meeting", "meetings")
        case .video: return ("video", "videos")
        case .xPost: return ("post", "posts")
        case .manual: return ("source", "sources")
        }
    }

    private func setDropTargeted(_ targeted: Bool) {
        dropTargetResetTask?.cancel()
        if targeted {
            isDropTargeted = true
            return
        }

        dropTargetResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            isDropTargeted = false
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        StudioDragVisibility.shared.endSoon()
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArtifact.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArtifact.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArtifactTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        await addDocToChatContext(transfer.artifactID)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioGroup.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGroup.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioGroupTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        let articles = vm.sourceIDsForGroupInOrder(transfer.groupName).compactMap { id in
                            vm.articles.first { $0.id == id }
                        }
                        await addArticlesToChatContext(articles)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        // The payload is the snapshot of what the learner picked
                        // up; the live selection may have moved on by the drop.
                        await addSourceIDsToChatContext(transfer.draggedSourceIDs)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioSourceID.identifier) { data, _ in
                    guard let data,
                          let sourceID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !sourceID.isEmpty else { return }
                    Task { @MainActor in
                        await addSourceIDsToChatContext([sourceID])
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        // A picture is for the message, not the library: there
                        // is no image source type, and what the learner means
                        // by dropping a screenshot is "look at this".
                        if Self.isImageFile(url) {
                            await attachImageFile(url)
                            return
                        }
                        let previousIDs = Set(vm.contextSourceIds)
                        await vm.importDroppedFile(url: url)
                        let newArticles = vm.contextSourceArticles.filter { !previousIDs.contains($0.id) }
                        await addArticlesToChatContext(newArticles)
                    }
                }
                continue
            }

            // Picture bytes without a file: an image dragged out of a browser or
            // another app, or one the catcher read off the pasteboard.
            if let imageType = provider.registeredTypeIdentifiers
                .compactMap({ UTType($0) })
                .first(where: { $0.conforms(to: .image) }) {
                handled = true
                let name = provider.suggestedName ?? "Dropped image.\(imageType.preferredFilenameExtension ?? "png")"
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        await attachImageData(data, name: name)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    let text: String?
                    if let string = item as? String {
                        text = string
                    } else if let data = item as? Data {
                        text = String(data: data, encoding: .utf8)
                    } else {
                        text = nil
                    }
                    guard let text else { return }
                    Task { @MainActor in
                        let previousIDs = Set(vm.contextSourceIds)
                        await vm.importDroppedText(text)
                        let newArticles = vm.contextSourceArticles.filter { !previousIDs.contains($0.id) }
                        await addArticlesToChatContext(newArticles)
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Attached pictures

    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    @MainActor
    private func attachImageFile(_ url: URL) async {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, !data.isEmpty else {
            manager.errorMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        await attachImageData(data, name: url.lastPathComponent)
    }

    /// Prepares the picture off the main actor and puts it in the composer's
    /// tray. A file that is not a picture, or one that cannot be converted,
    /// is reported in the chat's error line rather than silently ignored.
    @MainActor
    private func attachImageData(_ data: Data, name: String) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ChatImagePreparation.prepare(data)
            }.value
            manager.attachImage(ChatImageAttachment(prepared: prepared, name: name))
        } catch {
            manager.errorMessage = "\(name): \(error.localizedDescription)"
        }
    }

    @MainActor
    private func attachPastedImages(_ pasted: [ChatPastedImage]) async {
        for item in pasted {
            switch item {
            case .file(let url):
                await attachImageFile(url)
            case .bytes(let data, let name):
                await attachImageData(data, name: name)
            }
        }
    }

    /// A Doc dropped on this chat joins its context, the way the Docs row's
    /// "Add to Chat" item does — but into this pane's conversation directly
    /// rather than through the window's chat request: the drop already named
    /// the chat it meant, so there is nothing to route.
    ///
    /// The stored revision is attached, not an editor's unsaved draft: that is
    /// the text `read_doc` returns, so the two cannot disagree about what
    /// the chat is holding.
    @MainActor
    private func addDocToChatContext(_ artifactID: String, announces: Bool = true) async {
        do {
            let snapshot = try await vm.artifactMarkdown(artifactID)
            manager.addContextDoc(ChatDocAttachment(snapshot: snapshot))
            if announces { vm.showToast("Added \(snapshot.artifact.title) to Chat") }
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    /// Cards of the canvas, handed to this chat by Add to Chat or Ask in Chat:
    /// they become chips and lines in what the model is told at once, and the
    /// text of the sources and Docs among them is brought in the way a dropped
    /// one is (`addSourceIDsToChatContext`, `addDocToChatContext`), so the
    /// model reads it, not just their names. A Site or Page the card names is
    /// attached; an animation, audio overview or reading has no text to read.
    @MainActor
    private func takeCanvasCards(_ handOff: KnowledgeMapChatCards) async {
        let leftOut = manager.addCanvasCards(
            canvasID: handOff.canvasID,
            name: handOff.canvasName,
            cards: handOff.cards,
            replacing: handOff.replaces
        )
        if leftOut > 0 {
            vm.showToast("A chat holds \(KnowledgeMapChatContext.cardLimit) cards at most: \(leftOut) were left out")
        }
        let held = Set(manager.canvasContext?.cards.map(\.ref) ?? [])
        let joined = handOff.cards.filter { held.contains($0.ref) }
        let sourceIDs = vm.knowledgeMapChatSourceIDs(joined)
        if !sourceIDs.isEmpty {
            await addSourceIDsToChatContext(sourceIDs)
        }
        for card in joined {
            guard let item = KnowledgeMap.ItemRef(card.ref), item.kind == .doc,
                  let artifact = vm.artifacts.first(where: { $0.id == item.id }),
                  ["doc", "site"].contains(KnowledgeMapModel.docType(artifact)) else { continue }
            await addDocToChatContext(item.id, announces: false)
        }
    }

    @MainActor
    private func addSourceIDsToChatContext(_ ids: [String]) async {
        adoptLiveNotebookSelection()
        vm.addSourcesToContext(ids)
        let articles = ids.compactMap { id in
            vm.articles.first { $0.id == id }
        }
        await addArticlesToActiveOrIdleChat(articles)
    }

    @MainActor
    private func addArticlesToChatContext(_ articles: [StudioArticle]) async {
        adoptLiveNotebookSelection()
        for article in articles {
            vm.addSourceToContext(article.id)
        }
        await addArticlesToActiveOrIdleChat(articles)
    }

    @MainActor
    private func addArticlesToActiveOrIdleChat(_ articles: [StudioArticle]) async {
        let articles = articles.filter { vm.isSourceIncludedInKnowledge($0) }
        guard !articles.isEmpty else {
            vm.showToast("This source family is excluded from search and AI in Settings.")
            return
        }
        await addArticlesToFocusNotebookPool(articles)
        let sourceIDs = Set(articles.map(\.id))
        await vm.ensureContextSourceContentLoaded(sourceIDs: sourceIDs)
        let refreshedArticles = articles.map { article in
            vm.articlesById[article.id] ?? article
        }
        await manager.addContextSources(refreshedArticles)
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    /// A source pulled into a Notebook's chat joins that Notebook.
    ///
    /// Bringing a source into a Notebook's chat *is* the act of adding it to
    /// the Notebook. Requiring a second curation step in the Notebooks panel
    /// would let the pool drift out of step with what is actually being
    /// studied — and the pool is what the assistant sees, so that drift costs
    /// real answers. Approved rather than pending for the same reason: the
    /// drop is the approval.
    ///
    /// Deliberately not symmetric. Detaching a source from a chat unloads it
    /// from context and leaves the Notebook untouched; removing it from the
    /// Notebook stays a separate, deliberate act.
    @MainActor
    private func addArticlesToFocusNotebookPool(_ articles: [StudioArticle]) async {
        guard let notebook = linkedResearchNotebook else { return }
        let approved = Set(notebook.approvedSourceIDs)
        let newIDs = articles.map(\.id).filter { !approved.contains($0) }
        guard !newIDs.isEmpty else { return }

        do {
            // Same storage call `add_notebook_sources` uses over MCP, so the
            // pool, its sync_changes row, and the other Mac all agree. It
            // already re-approves a previously rejected source, which is the
            // behavior we want: using a source overrides an earlier removal.
            try await vm.storage.addCompanionSeedSources(goalID: notebook.id, sourceIDs: newIDs)
            await vm.loadLearningGoals()
        } catch {
            // Surfaced rather than swallowed. A pool that silently fails to
            // grow leaves the Notebook disagreeing with the chat that filled
            // it, and the source never reaches the other device at all.
            vm.errorMessage = "Could not add the source to \(notebook.title). \(error.localizedDescription)"
        }
    }

    @MainActor
    private func removeSourceFromChatContext(_ sourceID: String) {
        adoptLiveNotebookSelection()
        vm.removeSourceFromContext(sourceID)
        if reviewSources.isEmpty {
            isContextSourcesPopoverPresented = false
        }
        guard manager.linkedSourceIDs.contains(sourceID) else { return }
        Task {
            await manager.removeContextSource(sourceID, availableArticles: vm.articles)
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    @MainActor
    private func closeDeletedActiveSession() {
        if let sessionID = manager.currentSessionID {
            sessionStore.setDraft("", for: .session(sessionID))
        }
        manager.endSession()
        clearComposer()
        pendingReaderSelection = nil
    }

    @MainActor
    private func resetRequestedChatIfNeeded() {
        guard let requestID = vm.reviewChatResetRequestID else { return }
        // A Doc's passage asks for its new chat before it arrives, and this
        // runs first. When this chat is already working on that Doc the
        // passage joins it instead: nothing is reset, a running turn keeps
        // running, and the passage waits under the composer beside what the
        // learner has typed.
        if let request = vm.readerSelectionExplanationRequest, docPassageJoinsThisChat(request) {
            vm.pendingReviewChatNotebookID = nil
            vm.pendingReviewChatDraft = nil
            vm.pendingReviewChatCanvasQuestions = []
            vm.pendingReviewChatMode = nil
            vm.reviewChatResetRequestID = nil
            return
        }
        if sessionStore.prepareForNewChat(requestID: requestID) {
            return
        }
        // A chat opened beside the Canvas offers its questions; every other
        // fresh chat offers none.
        canvasSuggestedQuestions = vm.pendingReviewChatCanvasQuestions
        vm.pendingReviewChatCanvasQuestions = []
        manager.endSession()
        // Cards asked for with this chat (Ask in Chat, Add to Chat with no
        // chat beside the canvas) are its context from the first moment.
        if let handOff = vm.pendingChatCanvasCards,
           windowState == nil || windowState?.id == handOff.windowID {
            vm.pendingChatCanvasCards = nil
            Task { await takeCanvasCards(handOff) }
        }
        // A request naming a mode of its own — a notebook Studio's Deep
        // research — opens the fresh chat in it, ready for the question.
        if let mode = vm.pendingReviewChatMode {
            vm.pendingReviewChatMode = nil
            manager.setAssistantMode(mode)
        }
        // The Notebook link is settled before the draft, because it is half of
        // the scope the kept draft is filed under. A request naming none is
        // filed in the notebook the window holds: a library chat asked for
        // from one has left it already.
        if let notebookID = vm.pendingReviewChatNotebookID ?? windowNotebookForNewChat,
           vm.notebook(id: notebookID) != nil {
            linkedResearchNotebookID = notebookID
        } else {
            linkedResearchNotebookID = nil
        }
        // A notebook opening in this window asked for this chat: it reads the
        // notebook's ticks live, with nothing written until the learner acts.
        if vm.pendingNotebookChatRequestID == requestID, linkedResearchNotebookID != nil {
            readsNotebookTicksLive = true
            vm.pendingNotebookChatRequestID = nil
        } else {
            readsNotebookTicksLive = false
        }
        // A seeded draft is machine-inserted, so mark it overwritable the same way
        // `explainCurrentReading` does. With nothing seeded, this New chat gets
        // back whatever was left unsent in it before the learner navigated off.
        draft = vm.pendingReviewChatDraft ?? sessionStore.draft(for: currentDraftScope)
        lastInsertedDefaultPrompt = vm.pendingReviewChatDraft
        vm.pendingReviewChatDraft = nil
        pendingReaderSelection = nil
        vm.pendingReviewChatNotebookID = nil
        vm.reviewChatResetRequestID = nil
    }

    @MainActor
    private func startRequestedReviewChat() async {
        // The Memory row asked for today's review. The cohort is already
        // assembled; the manager plans it and the tutor opens.
        if let pending = vm.pendingMemoryReview {
            vm.pendingMemoryReview = nil
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let articles = pending.cohort.sources
                .map(\.sourceID)
                .compactMap { vm.articlesById[$0] }
                .filter { vm.isSourceIncludedInKnowledge($0) }
            await manager.startMemoryReview(pending, articles: articles)
            await vm.loadReviewSessionLinks()
            return
        }

        // Generate in the Courses tab: a new, empty chat with the course's
        // opening sentence typed for the learner to finish. The instructions
        // go with that first message (`CoursePlanningChat`).
        if vm.pendingCoursePlanningChat {
            vm.pendingCoursePlanningChat = false
            // From a notebook's Studio the chat is the notebook's: filed in
            // it, its ticked sources already the chat's context
            // (`startCoursePlanningChat(inNotebook:)`).
            let notebook = vm.pendingCoursePlanningNotebookID.flatMap { vm.notebook(id: $0) }
            vm.pendingCoursePlanningNotebookID = nil
            // A turn under way keeps the chat: the press says so rather
            // than doing nothing where the learner can see.
            guard !manager.isSearching, !manager.isGenerating else {
                vm.showToast("Plan the course once this answer finishes")
                return
            }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            manager.setAssistantMode(.assistant)
            clearComposer()
            pendingReaderSelection = nil
            manager.clearStagedSources()
            linkedResearchNotebookID = notebook?.id
            readsNotebookTicksLive = false
            draft = notebook.map { CoursePlanningChat.openingDraft(notebookTitle: $0.title) }
                ?? CoursePlanningChat.openingDraft
            coursePlanningArmed = true
            requestComposerFocus()
            return
        }

        // A course quiz row asked to take its quiz: a new chat on the lecture
        // sources, the tutor asking the stored questions.
        if let pending = vm.pendingCourseQuiz {
            vm.pendingCourseQuiz = nil
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let articles = pending.sourceIDs.compactMap { vm.articlesById[$0] }
            await manager.startCourseQuiz(pending, articles: articles)
            await vm.loadReviewSessionLinks()
            return
        }

        // The Studio's Feynman Technique asked for a chat on one paper: a
        // new chat in the notebook, the paper loaded in full, opening on the
        // written ask to explain it (`ReviewSessionManager.startTeachBack`).
        if let pending = vm.pendingTeachBack {
            vm.pendingTeachBack = nil
            // A turn under way keeps the chat: the press says so rather
            // than doing nothing where the learner can see.
            guard !manager.isSearching, !manager.isGenerating else {
                vm.showToast("Start the Feynman Technique once this answer finishes")
                return
            }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            linkedResearchNotebookID = vm.notebook(id: pending.notebookID)?.id
            readsNotebookTicksLive = false
            guard await syncSynthesisToolContext() else { return }
            await vm.ensureContextSourceContentLoaded(sourceIDs: [pending.sourceID])
            guard let paper = vm.articlesById[pending.sourceID] else { return }
            await manager.startTeachBack(pending, articles: [paper])
            await vm.loadReviewSessionLinks()
            return
        }

        // A Learning Companion goal asked for a goal-linked review: seed it with the
        // goal's own sources/topic and stamp goal_id so completing it advances the goal.
        if let pending = vm.pendingCompanionReview {
            vm.pendingCompanionReview = nil
            let articles = pending.sourceIDs
                .compactMap { vm.articlesById[$0] }
                .filter { vm.isSourceIncludedInKnowledge($0) }
            guard !articles.isEmpty else { return }
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let notebookScopeID: String?
            if let goalID = pending.goalID, vm.notebook(id: goalID) != nil {
                notebookScopeID = goalID
            } else {
                notebookScopeID = nil
            }
            await manager.startSession(
                topic: pending.topic,
                articles: articles,
                goalID: pending.goalID,
                notebookScopeID: notebookScopeID,
                dailyPlanRationale: pending.rationale,
                memoryPlan: pending.memoryPlan
            )
            await vm.loadReviewSessionLinks()
            return
        }

        adoptLiveNotebookSelection()
        guard !reviewSources.isEmpty else { return }
        guard !manager.isSearching, !manager.isGenerating else { return }
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            manager.endSession()
        }
        clearComposer()
        pendingReaderSelection = nil
        guard await syncSynthesisToolContext() else { return }
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(
            topic: reviewTitle,
            articles: reviewSources,
            goalID: linkedResearchNotebookID,
            notebookScopeID: linkedResearchNotebookID
        )
        await vm.loadReviewSessionLinks()
    }

    private func resumeRequestedSessionIfNeeded() async {
        guard let sessionID = requestedResumeSessionID else { return }
        let isStoreRequest = sessionStore.requestedSessionID == sessionID

        switch sessionStore.prepareToOpen(sessionID: sessionID) {
        case .switched:
            return
        case .alreadyLoaded, .needsResume:
            break
        }
        defer {
            sessionStore.didResume(sessionID: sessionID)
            if isStoreRequest {
                sessionStore.didConsumeOpenRequest(sessionID: sessionID)
            } else if acceptsGlobalNavigationRequests {
                vm.reviewChatResumeSessionID = nil
            }
        }

        if vm.reviewSessionLinks.isEmpty {
            await vm.loadReviewSessionLinks()
        }
        guard let session = vm.reviewSessionLinks.first(where: { $0.id == sessionID }) else {
            if let sourceID = sessionStore.takeWalkthroughAfterOpen(sessionID: sessionID) {
                await startWalkthroughPlayback(sourceID: sourceID)
            }
            return
        }

        if manager.currentSessionID == sessionID {
            showAlreadyLoadedSession(session)
        } else {
            await openSessionFromHistory(session)
        }
        // Walk Through opened the walk's own chat: the walk plays on over it.
        if let sourceID = sessionStore.takeWalkthroughAfterOpen(sessionID: sessionID) {
            await startWalkthroughPlayback(sourceID: sourceID)
        }
    }

    @MainActor
    private func showAlreadyLoadedSession(_ session: ReviewSessionRecord) {
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? session.sourceIDs : manager.linkedSourceIDs
        if acceptsGlobalNavigationRequests {
            readsNotebookTicksLive = false
            vm.setContextSources(sourceIDs)
        }
        if let goalID = session.goalID, vm.notebook(id: goalID) != nil {
            linkedResearchNotebookID = goalID
        } else {
            linkedResearchNotebookID = nil
        }
        draft = sessionStore.draft(for: .session(session.id))
        composer.referencedChats = []
        lastInsertedDefaultPrompt = nil
        pendingReaderSelection = nil
    }

    @MainActor
    private func openSessionFromHistory(_ session: ReviewSessionRecord) async {
        guard session.isLocalMCPSession else { return }
        let sources = vm.linkedSources(for: session).filter { vm.isSourceIncludedInKnowledge($0) }
        if acceptsGlobalNavigationRequests {
            readsNotebookTicksLive = false
            vm.setContextSources(session.sourceIDs)
        }
        let notebookScopeID: String?
        if let goalID = session.goalID, vm.notebook(id: goalID) != nil {
            notebookScopeID = goalID
        } else {
            notebookScopeID = nil
        }
        linkedResearchNotebookID = notebookScopeID
        // A quiz's chat goes on grading where it stopped, while its quiz
        // is still in the course.
        let courseQuiz = await vm.courseQuizChatRequest(forSessionID: session.id)
        await manager.resumeSession(
            session,
            articles: sources,
            notebookScopeID: notebookScopeID,
            courseQuiz: courseQuiz
        )
        draft = sessionStore.draft(for: .session(session.id))
        composer.referencedChats = []
        lastInsertedDefaultPrompt = nil
        pendingReaderSelection = nil
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    private func errorText(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // Clamped at the boundary as well as at the source. Errors
                // reach this row from providers, storage, sync, and MCP, and a
                // failure that hands back a payload instead of a sentence must
                // never be able to paste it into the chat.
                Text(AIProviderErrorText.clamped(message))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    clearDisplayedError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .help("Dismiss error")
            }

            // Nothing can pay for the answer, and retrying cannot succeed — the
            // account, not the model, refused. Offer AI Usage in its place:
            // the key, the limits, and a way to the plan when there is none.
            if AICreditEntitlement.isBlockedByBudget(message) {
                Button {
                    clearDisplayedError()
                    NotificationCenter.default.post(
                        name: .requestOpenStudioSettings,
                        object: SettingsPane.aiUsage
                    )
                } label: {
                    Label("Open AI Usage", systemImage: "sparkles")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else if manager.canRetryLastGeneration && dictation.errorMessage == nil {
                Button {
                    Task {
                        await manager.retryLastGeneration()
                        await vm.loadReviewSessionLinks()
                        await vm.loadLearningGoals()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(manager.isGenerating || manager.isSearching)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func clearDisplayedError() {
        manager.errorMessage = nil
        dictation.errorMessage = nil
        speech.errorMessage = nil
    }
}


/// The rows of one chat, in a view of their own so that a streamed token
/// re-evaluates this and nothing else.
///
/// `ReviewSessionManager` is `@Observable`, and Observation tracks a
/// dependency per property read: any body that touches `chatMessages` — even
/// only to ask how many there are — is re-evaluated by every content publish of
/// the streaming answer, a dozen times a second. The panel around this
/// transcript is thousands of lines of header, context chips and composer, and
/// sampling a scroll during a reply put that body, with the regrouping of every
/// message inside it, among the main thread's top costs. So the panel reads the
/// manager's coarse `chatMessageCount`, and the one body that reads the
/// messages is this one. The row builder and error view come from the panel as
/// closures, so the rows themselves are unchanged.
private struct ReviewChatTranscriptStack<Row: View, ErrorView: View>: View {
    let manager: ReviewSessionManager
    let proxy: ScrollViewProxy
    let isTurnInFlight: Bool
    /// What a walk is doing while it has no step to show yet, if anything:
    /// shown as the working line, so pressing Walk Through or Next is not a
    /// silent wait.
    let walkthroughPreparation: String?
    let turnStartedAt: Date?
    let errorMessage: String?
    /// Empty space kept under the last row; see the panel's `transcriptBottomReserve`.
    let bottomReserve: CGFloat
    /// A memory review drawn as cards: the transcript holds the one card's
    /// exchange (`MemoryReviewCardFold`). False for every other chat.
    let showsMemoryCards: Bool
    /// The deck dealt a topic or a source a card: the rows on it carry what
    /// the card is about and its foot, and the wait for a grade reads
    /// "Reading your answer".
    let showsTopicCards: Bool
    /// The answer field stays under the steers once the card is graded: a
    /// source-by-source tutor can ask its next probe in the graded reply.
    let answersAfterGrade: Bool
    /// The card's answer field: an answer, or an honest miss.
    let sendMemoryAnswer: (String) -> Void
    let dontRememberMemoryAnswer: () -> Void
    /// The card chosen with Back and Next; nil for the newest.
    let memoryCardIndex: Int?
    /// The height the rows fill from the top: a card's viewport, so the card
    /// stands full height with its question at the top. Zero for every other
    /// chat.
    let minContentHeight: CGFloat
    let columnMaxWidth: CGFloat
    /// Width of one bubble; the queued rows draw at the same width as the sent ones.
    let messageMaxWidth: CGFloat
    /// The × on a queued row: the message goes back to the composer.
    let returnQueuedFollowUp: (ReviewSessionManager.QueuedFollowUp) -> Void
    /// The ↑ on a queued row: the running reply stops and this message goes next.
    let sendQueuedFollowUpNow: (ReviewSessionManager.QueuedFollowUp) -> Void
    /// A name in the sources-added row: that source opens in the reader.
    let openContextSource: (String) -> Void
    /// The ways on from a side question, drawn by the lane under the newest
    /// aside: back to the tutor's open question (answer it, or let it go), or
    /// on with the side question (a follow-up here, or a chat of its own).
    let answerOpenQuestion: () -> Void
    let skipOpenQuestion: () -> Void
    let followUpSideQuestion: () -> Void
    let openSideQuestionInNewChat: () -> Void
    /// More details pressed on a reply whose lane already exists: that lane
    /// opens and the transcript scrolls to it.
    let laneExpansionRequest: ReviewChatLaneExpansionRequest?
    /// Which source each `[n]` names, and whose card has been listed already.
    /// Written here rather than read here: the rows belong to the panel, but
    /// this is the view that already watches the messages, and rebuilding the
    /// ledger up there would make the whole panel re-evaluate per streamed
    /// token. See `ChatCitationLedger`.
    @Binding var citationContexts: [UUID: ChatCitationLedger.MessageContext]
    /// Builds one block; the context says whether it is the block the running
    /// turn is writing into, whether it is the newest block (where a memory
    /// review's steer chips sit once the reply has landed), whether it sits in
    /// a side question's lane, and which More details lane already hangs
    /// under it.
    let row: (ReviewChatTranscriptBlock, ReviewChatTranscriptRowContext) -> Row
    let errorText: (String) -> ErrorView

    var body: some View {
        // Grouped once per render: the last block is the one the running turn is
        // still writing into, and both the ForEach and the live flag need it.
        // A playing walk shows the conversation of the card on screen; the
        // card itself is drawn above the chat.
        // A memory review drawn as cards shows the one card's exchange; an
        // older card is a record, so nothing that belongs to the turn being
        // answered — the steer chips, the working line, the ways back from a
        // side question — is drawn on it.
        let walkMessages = WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
        let card = showsMemoryCards
            ? MemoryReviewCardFold.thread(walkMessages, selected: memoryCardIndex, byTopic: showsTopicCards)
            : (messages: walkMessages, isNewest: true, sourceID: nil)
        let messages = card.messages
        let showsNewest = card.isNewest
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        let liveBlockID = isTurnInFlight && showsNewest ? blocks.last?.id : nil
        // Newest by time: a lane about an older reply is drawn up under it.
        let newestSectionID = showsNewest ? ReviewChatTranscriptSection.newest(in: sections, blocks: blocks)?.id : nil
        // A topic card: what its foot carries, and its last block outside any
        // side question's lane, where the ledger hangs.
        let subjectID = card.sourceID ?? (showsTopicCards && card.isNewest ? manager.memoryReviewCurrentSourceID : nil)
        let topicFoot = showsTopicCards ? topicCardFoot(card, subjectID: subjectID) : .none
        let lastMainBlockID = showsTopicCards
            ? sections.last(where: { !$0.isSideQuestion })?.blocks.last?.id
            : nil
        let firstMainBlockID = showsTopicCards
            ? sections.first(where: { !$0.isSideQuestion })?.blocks.first?.id
            : nil
        // Each reply's More details lane, so its footer reopens the lane
        // instead of asking for a second one.
        let moreDetailsLanes: [UUID: UUID] = sections.reduce(into: [:]) { lanes, section in
            guard section.isSideQuestion, section.isMoreDetails, let aboutID = section.aboutBlockID else { return }
            if lanes[aboutID] == nil { lanes[aboutID] = section.id }
        }
        let context: (ReviewChatTranscriptBlock, ReviewChatTranscriptSection) -> ReviewChatTranscriptRowContext = { block, section in
            ReviewChatTranscriptRowContext(
                isLive: block.id == liveBlockID,
                isLatest: showsNewest && block.id == blocks.last?.id,
                isInsideAside: section.isSideQuestion,
                moreDetailsLaneID: moreDetailsLanes[block.id],
                isLastOnCard: lastMainBlockID != nil && block.id == lastMainBlockID,
                isFirstOnCard: firstMainBlockID != nil && block.id == firstMainBlockID,
                memoryCardTopicID: showsTopicCards ? subjectID : nil,
                memoryCardFoot: topicFoot
            )
        }
        // Lazy is load-bearing: each assistant bubble hosts a WKWebView, and
        // materializing a whole chat's worth at once on a session switch stalls
        // the main thread. Only the visible screenful may be built eagerly.
        LazyVStack(alignment: .leading, spacing: 14) {
            // A finished review's graded summary: a quiet caption, the
            // grader's words, with no box around them.
            if showsNewest, let summary = manager.completedSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: messageMaxWidth, alignment: .leading)
            }

            // A side question and its replies share one lane, which folds once
            // the quiz has moved on. Every block keeps its own id: the scroll
            // anchors below are message ids, wherever the message sits.
            ForEach(sections) { section in
                if section.isSideQuestion {
                    ReviewChatAsideLane(
                        section: section,
                        isLatest: section.id == newestSectionID,
                        isLive: section.blocks.contains { $0.id == liveBlockID },
                        expandRequest: laneExpansionRequest?.laneID == section.id ? laneExpansionRequest?.token : nil,
                        answerOpenQuestion: answerOpenQuestion,
                        skipOpenQuestion: skipOpenQuestion,
                        followUpSideQuestion: followUpSideQuestion,
                        openSideQuestionInNewChat: openSideQuestionInNewChat
                    ) { block in
                        row(block, context(block, section))
                            .id(block.id)
                    }
                } else {
                    ForEach(section.blocks) { block in
                        row(block, context(block, section))
                            .id(block.id)
                    }
                }
            }

            // Sources the learner brought in since their last message. The row
            // stands here until that message is sent, then moves up above it,
            // written beside it (`ChatContextAdditions`).
            if showsNewest {
                if !manager.pendingContextAdditions.isEmpty {
                    ReviewChatContextAdditionsRow(
                        added: manager.pendingContextAdditions,
                        maxContentWidth: messageMaxWidth,
                        openSource: openContextSource
                    )
                }

                activityStatus(topicFoot: topicFoot)

                // The answer field, right under the question it answers.
                if showsTopicCards, topicFoot == .answer || (answersAfterGrade && topicFoot == .steer) {
                    MemoryReviewTopicAnswerField(
                        isBusy: isTurnInFlight,
                        send: sendMemoryAnswer,
                        dontRemember: dontRememberMemoryAnswer
                    )
                }

                // Messages sent while the turn above was still running. They sit
                // under it, dimmed, until it ends and they move up as real turns.
                ForEach(manager.queuedFollowUps) { item in
                    ReviewChatQueuedFollowUpRow(
                        text: item.text,
                        maxContentWidth: messageMaxWidth,
                        returnToComposer: { returnQueuedFollowUp(item) },
                        sendNow: { sendQueuedFollowUpNow(item) }
                    )
                    .id(item.id)
                }

                if let errorMessage {
                    errorText(errorMessage)
                }
            }

            // Never let the transcript end flush against the composer.
            Color.clear.frame(height: bottomReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, showsMemoryCards ? MemoryReviewCardSurface.contentInset : 14)
        .padding(.top, showsMemoryCards ? 10 : 12)
        // The stack's spacing already stands over the empty reserve row.
        .padding(.bottom, showsMemoryCards ? 6 : 12)
        .frame(minHeight: minContentHeight, alignment: .top)
        // The scroll view stays full-width (scrollbar at the panel edge,
        // drops land anywhere); only the content column is capped.
        .frame(maxWidth: columnMaxWidth)
        .frame(maxWidth: .infinity)
        // Tells the streaming bubbles when the transcript is moving, whatever
        // is moving it, so they hold their resizes and text until it stops.
        .background(ChatTranscriptScrollObserver())
        // Which replies exist is what moves the ledger. A streaming reply's own
        // text cannot: nothing below it is written yet, and its context was
        // settled by the transcript it arrived into -- the whole cast so far,
        // since the ledger cannot know yet which of it the reply will cite.
        // The manager appends the reply and names it as streaming in one
        // step, so the id change always sees the streaming id already set.
        .onChange(of: manager.chatMessages.map(\.id), initial: true) { _, _ in
            citationContexts = ChatCitationLedger.contexts(
                for: manager.chatMessages.compactMap { message in
                    // Only an assistant reply renders markdown, so only an
                    // assistant reply can cite: a source link a learner typed is
                    // their own text and never becomes a numbered citation.
                    guard message.role == .assistant,
                          message.toolActivity == nil,
                          let markdown = ReviewSessionManager.displayableMessageContent(
                              role: message.role,
                              content: message.content
                          )
                    else { return nil }
                    return ChatCitationLedger.Entry(id: message.id, markdown: markdown)
                },
                open: manager.streamingMessageID
            )
        }
        .onChange(of: latestUserMessageID) { _, _ in
            // Scroll only when the user submits a message (or a session loads
            // its history). A fresh send leaves the user's message as the last
            // visible row: center it so the reply streams into the lower half
            // of the viewport. Loading history lands at the bottom instead.
            guard let message = latestVisibleChatMessage else { return }
            // A card is dealt with the answer at its top and the reply
            // growing under it, so a sent answer that has pushed the card
            // past its height is read from there.
            let anchor: UnitPoint = message.role == .user ? (showsMemoryCards ? .top : .center) : .bottom
            // Defer one tick so the reserved streaming space below the message
            // is laid out first; scrolling immediately clamps to the previous
            // content height and leaves the message pinned to the bottom.
            let id = message.id
            DispatchQueue.main.async {
                scrollToMessage(id, anchor: anchor)
            }
        }
        .onChange(of: laneExpansionRequest) { _, request in
            // More details pressed again: the lane opens (its own onChange),
            // and the transcript brings its heading into view. Deferred a tick
            // so the lane has laid its rows out before the scroll measures it.
            guard let request else { return }
            DispatchQueue.main.async {
                scrollToMessage(request.laneID, anchor: .top)
            }
        }
        .onChange(of: memoryCardIndex) { _, selected in
            // Back or Next through the deck: an older card opens at its top,
            // the newest at its end, where the question waits.
            guard showsMemoryCards else { return }
            let thread = MemoryReviewCardFold.thread(manager.chatMessages, selected: selected, byTopic: showsTopicCards)
            let cardBlocks = ReviewChatTranscriptBlock.grouping(thread.messages)
            guard let target = thread.isNewest ? cardBlocks.last : cardBlocks.first else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(target.id, anchor: thread.isNewest ? .bottom : .top)
            }
        }
        .onChange(of: manager.walkthroughStepScrollRequest) { _, request in
            // A move in the walk: the chat under the card shows the end of
            // that card's conversation. Deferred a tick so the new card's
            // thread is laid out first.
            guard request != nil else { return }
            let thread = WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
            guard let last = ReviewChatTranscriptBlock.grouping(thread).last else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// What the running turn is doing, named for the learner.
    private var workingPhase: ReviewChatWorkingIndicator.Phase {
        // A walk getting a step ready is preparing, whatever else is idle: its
        // detail names the step, and no model has been asked anything.
        if walkthroughPreparation != nil, !manager.isGenerating { return .preparing }
        if manager.isPlanningMemoryReview { return .planning }
        if manager.isSearching { return .searching }
        guard manager.isGenerating else { return .preparing }
        guard let streamingID = manager.streamingMessageID,
              let streamed = manager.chatMessages.last(where: { $0.id == streamingID }) else {
            return .thinking
        }
        return streamed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .thinking
            : .writing
    }

    /// What the newest topic card's foot carries: the answer field, the wait
    /// for a grade, or the two steers (`MemoryReviewTopicCardFold.foot`).
    private func topicCardFoot(
        _ card: (messages: [ReviewSessionManager.Message], isNewest: Bool, sourceID: String?),
        subjectID: String?
    ) -> MemoryReviewTopicCardFoot {
        let graded = subjectID.map { manager.memoryReviewStatusBySource[$0] != nil } ?? false
        return MemoryReviewTopicCardFold.foot(
            card.messages,
            isNewest: card.isNewest,
            isGraded: graded,
            isBusy: isTurnInFlight
        )
    }

    @ViewBuilder
    private func activityStatus(topicFoot: MemoryReviewTopicCardFoot) -> some View {
        if topicFoot == .reading, workingPhase != .writing {
            // A topic card grading an answer: one breathing line, and no
            // Thinking disclosure (docs/memory-design.md, "Review by topic").
            MemoryReviewReadingAnswerLine()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } else if isTurnInFlight || walkthroughPreparation != nil {
            // The mark rather than a spinner: this is the wait for a reply, and a
            // system spinner here reads as the machine being busy where the mark
            // reads as the product thinking. Tool rows keep their spinners.
            ReviewChatWorkingIndicator(
                phase: workingPhase,
                detail: walkthroughPreparation ?? manager.sendPreparationDetail,
                startedAt: turnStartedAt ?? Date(),
                // A topic card shows no thinking; the conversation keeps it.
                reasoning: showsTopicCards ? "" : manager.streamingReasoning
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)

            // The wait for a live plan is the one moment the offer to move it
            // to the morning is obviously relevant. The view decides whether
            // it still stands and keeps its confirmation up for the rest of
            // the turn once taken, so it lives for the whole turn.
            MemoryReviewPreparationOffer(
                isPlanning: workingPhase == .planning,
                startedAt: turnStartedAt ?? Date()
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // A free model that has said nothing for a while: the offer to
            // ask a paid one instead, until Don't Ask Again.
            SlowFreeModelOffer(
                turnModel: manager.turnModel,
                isWaitingForText: workingPhase == .thinking,
                askAgain: { manager.restartTurnOnSelectedModel() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The newest user-authored message. Used purely as an onChange trigger so the
    /// transcript scrolls once per submitted message instead of following every
    /// streamed token or appended tool row.
    private var latestUserMessageID: UUID? {
        manager.chatMessages.last(where: { $0.role == .user })?.id
    }

    private var latestVisibleChatMessage: ReviewSessionManager.Message? {
        manager.chatMessages.last(where: isVisibleChatMessage)
    }

    private func isVisibleChatMessage(_ message: ReviewSessionManager.Message) -> Bool {
        // Tool rows carry no text content but are rendered, so they must count as
        // visible or the transcript would scroll past the very activity it is showing.
        if message.toolActivity != nil { return true }
        return ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private func scrollToMessage(_ id: UUID, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

/// An attached Doc in the "In context" list.
///
/// Deliberately plainer than a source row: a Doc has no cover art, no reader to
/// open it in from here, and nothing to say about itself beyond its name.
private struct ContextDocCard: View {
    let doc: ChatDocAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(doc.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Built only under the pointer, the hidden glyph holding its
            // place: a button at opacity 0 is still a live control, and while
            // an assistive app reads the screen SwiftUI walks every control
            // in the window for each one an update builds (2026-10-03).
            if isHovering {
                Button(action: onRemove) {
                    ContextCardRemoveGlyph()
                }
                .buttonStyle(.hoverWash(in: Circle()))
                .help("Remove \(doc.title) from chat context")
            } else {
                ContextCardRemoveGlyph()
                    .hidden()
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page in context: \(doc.title)")
        // The × for VoiceOver, which has no pointer to bring it out; while
        // the × is built, the combined element carries its press already.
        .accessibilityActions {
            if !isHovering {
                Button("Remove from Chat Context", action: onRemove)
            }
        }
    }
}

/// The × on an "In context" card, and, hidden, what holds its place while
/// the button is not built.
private struct ContextCardRemoveGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }
}

/// One source in the composer's "In context" popover. Its own view so each row can
/// own a hover state: the row highlights and the remove button fades in only under
/// the pointer, which keeps a list of sources from reading as a wall of ✕ buttons.
private struct ContextSourceCard: View {
    let source: StudioArticle
    let metadataVisibility: MetadataVisibilitySettings
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            ArticleRow(article: source, metadataVisibility: metadataVisibility)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensInOtherWindow(source)
        .help("Open \(source.title) in the reader")
        // The × for VoiceOver, which has no pointer to bring it out.
        .accessibilityAction(named: Text("Remove from Chat Context"), onRemove)
        .padding(.leading, 8)
        // Room for the remove button so its fade-in never reflows the row.
        .padding(.trailing, 26)
        .padding(.vertical, 5)
        // This wash spans the row including the space the remove button fades into,
        // so it is the one that stays; `ArticleRow` drops its narrower one.
        .ownsRowHoverWash()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .overlay(alignment: .topTrailing) {
            // Built only under the pointer: a button at opacity 0 is still a
            // live control, and while an assistive app reads the screen
            // SwiftUI walks every control in the window for each one an
            // update builds (2026-10-03). The padding above holds its room.
            if isHovering {
                Button(action: onRemove) {
                    ContextCardRemoveGlyph()
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: 0))
                .help("Remove \(source.title) from chat context")
                .padding(.top, 7)
                .padding(.trailing, 5)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The material a day's memory review covers, pinned above its transcript.
///
/// A memory review is a conversation about specific sources, and the
/// conversation alone never says which ones, nor how far through them the day
/// is. The strip says both: every source the review carries, with its cover,
/// and a check on each one whose contour has been graded.
/// One chip in the day's review strip: a library source, or a chat the
/// review carries under its session id.
private struct MemoryReviewStripEntry: Identifiable {
    let id: String
    let title: String
    /// Nil for a chat, which is review material without being a source row.
    let article: StudioArticle?
}

private struct MemoryReviewSourceStrip: View {
    let sources: [MemoryReviewStripEntry]
    let statusBySource: [String: MemoryReviewSourceStatus]
    /// The source the tutor is asking about right now; its chip is ringed and
    /// scrolled into view, so the strip reads done, current, upcoming.
    let currentSourceID: String?
    /// True while a turn is in flight; a click then would land mid-reply.
    let isBusy: Bool
    let bookCoverPath: (StudioArticle) -> String?
    let columnMaxWidth: CGFloat
    let gutter: CGFloat
    /// A hairline under the strip, over a scrolling conversation. A card
    /// floats under the strip on its own and needs none.
    let separated: Bool
    /// The learner clicked a source: steer the review to it.
    let steer: (MemoryReviewStripEntry) -> Void
    /// Open the source in the reader, from the chip's context menu.
    let open: (String) -> Void
    /// The learner clicked a chip's ×: take the source out of today's review.
    let remove: (MemoryReviewStripEntry) -> Void

    private var reviewedCount: Int {
        sources.filter { statusBySource[$0.id] != nil }.count
    }

    private var isComplete: Bool { reviewedCount == sources.count }

    /// Says where the day stands, in the terms the review itself uses.
    private var summary: String {
        if reviewedCount == 0 {
            return sources.count == 1 ? "1 source today" : "\(sources.count) sources today"
        }
        if isComplete {
            return sources.count == 1
                ? "Reviewed today"
                : "All \(sources.count) reviewed today"
        }
        return "\(reviewedCount) of \(sources.count) reviewed today"
    }

    /// The chip scrolled to the middle of the strip. Scoped to the strip's own
    /// scroll view: a `ScrollViewReader` jump to the current chip is suspected
    /// of also scrolling the chat column it sits in, which left the pane's
    /// title, controls and this summary under the titlebar on entering a
    /// review (2026-09-25).
    @State private var centeredSourceID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green)
                            .zoomedSystemFont(size: 10)
                    }
                    Text(summary)
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(isComplete ? Color.green : Color.secondary)
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .lineLimit(1)
                        .fixedSize()
                }
                progressLine
            }
            .padding(.horizontal, gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { source in
                        MemoryReviewSourceChip(
                            source: source,
                            bookCoverPath: source.article.flatMap(bookCoverPath),
                            status: statusBySource[source.id],
                            isCurrent: source.id == currentSourceID,
                            isBusy: isBusy,
                            steer: { steer(source) },
                            // A chat has no reader to open it in.
                            open: source.article == nil ? nil : { open(source.id) },
                            // A graded contour is a record, and stays.
                            remove: statusBySource[source.id] == nil ? { remove(source) } : nil
                        )
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, gutter)
                .padding(.vertical, 2)
            }
            .scrollPosition(id: $centeredSourceID, anchor: .center)
            // Chips running past either end fade out rather than stop at a
            // hard edge mid-word.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: gutter)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: gutter + 6)
                }
            )
            .onChange(of: currentSourceID, initial: true) { _, current in
                guard let current, sources.contains(where: { $0.id == current }) else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    centeredSourceID = current
                }
            }
        }
        // Follow the transcript's reading column, summary included, so the
        // strip begins on the same leading outline as the card under it.
        .frame(maxWidth: columnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, separated ? 8 : 2)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if separated {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's review sources, \(summary)")
    }

    /// How far through the day's sources the review is, as a hairline.
    private var progressLine: some View {
        let fraction = sources.isEmpty ? 0 : CGFloat(reviewedCount) / CGFloat(sources.count)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(isComplete ? Color.green : Color.accentColor)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 160)
        .animation(.easeInOut(duration: 0.3), value: reviewedCount)
        .accessibilityHidden(true)
    }
}

/// One source in the review strip. Clicking steers the review to it: a source
/// already checked off gets probed deeper, one still waiting is taken now. The
/// reader is one right-click away, for "what did it actually say?". A source
/// not yet graded also carries a × under the pointer, for material the day
/// should not have picked; it is a sibling of the steer button, not part of
/// its label, so each click has exactly one owner.
private struct MemoryReviewSourceChip: View {
    let source: MemoryReviewStripEntry
    let bookCoverPath: String?
    /// Non-nil once this source's contour has been graded in this review.
    let status: MemoryReviewSourceStatus?
    /// True while the tutor's questions are about this source.
    let isCurrent: Bool
    /// True while a turn is in flight, when a steer would land mid-reply.
    let isBusy: Bool
    let steer: () -> Void
    /// Open the source in the reader; nil for a chat.
    let open: (() -> Void)?
    /// Take the source out of today's review; nil once it has been graded.
    let remove: (() -> Void)?

    @State private var isHovering = false

    private var isReviewed: Bool { status != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }

    private var helpText: String {
        let state: String
        if let status {
            state = status.recallSummary
        } else {
            state = "not reviewed yet"
        }
        let action = isReviewed ? "Click to go deeper" : "Click to review it now"
        let where_ = isCurrent ? "\(source.title) — reviewing now; \(state)" : "\(source.title) — \(state)"
        return open == nil ? "\(where_). \(action)." : "\(where_). \(action); right-click to open it."
    }

    private var accessibilityText: String {
        let reviewed = isReviewed ? "Reviewed" : "Not reviewed yet"
        return isCurrent ? "Reviewing now, \(reviewed.lowercased()): \(source.title)" : "\(reviewed): \(source.title)"
    }

    private var removeGlyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .background(Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let article = source.article {
            SourceThumbnail(source: article, size: 26, bookCoverPath: bookCoverPath)
        } else {
            Image(systemName: "bubble.left.and.bubble.right")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: steer) {
                HStack(spacing: 7) {
                    thumbnail
                        .overlay(alignment: .bottomTrailing) {
                            if isReviewed {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.green)
                                    .zoomedSystemFont(size: 11)
                                    .offset(x: 3, y: 3)
                            }
                        }
                    Text(source.title)
                        .zoomedSystemFont(size: 11.5, weight: isCurrent ? .medium : .regular)
                        .foregroundStyle(isReviewed && !isCurrent ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 5)
                .padding(.trailing, remove == nil ? 9 : 4)
                .padding(.vertical, 4)
                .contentShape(shape)
            }
            .buttonStyle(.hoverWash(in: shape, inset: 0))
            .disabled(isBusy)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(isReviewed ? "Go deeper on this source" : "Review this source now")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            if let remove {
                // Built only under the pointer, the hidden glyph holding its
                // place: a button at opacity 0 is still a live control, and
                // while an assistive app reads the screen SwiftUI walks every
                // control in the window for each one an update builds
                // (2026-10-03). The right-click and the named action below
                // remove it too.
                Group {
                    if isHovering {
                        Button(action: remove) {
                            removeGlyph
                        }
                        .buttonStyle(.hoverWash(in: Circle()))
                        .disabled(isBusy)
                        .help("Remove \(source.title) from today's review")
                        .accessibilityLabel("Remove \(source.title) from today's review")
                        .accessibilityIdentifier("mac.chatMemoryRemoveSource")
                    } else {
                        removeGlyph
                            .hidden()
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: 190, alignment: .leading)
        .background(
            shape.fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            shape.strokeBorder(
                isCurrent ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.06),
                lineWidth: isCurrent ? 1.5 : 1
            )
        )
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isReviewed ? "Go deeper on this" : "Review this now", action: steer)
                .disabled(isBusy)
            if let open {
                Button("Open in reader", action: open)
            }
            if let article = source.article {
                OtherWindowSourceMenuItem(article)
            }
            if let remove {
                Divider()
                Button("Remove from today's review", action: remove)
                    .disabled(isBusy)
            }
        }
        .accessibilityElement(children: .contain)
        // The × shows under the pointer; a screen reader has no pointer, so
        // the same removal is a named action on the chip.
        .modifier(MemoryReviewChipRemoveAction(remove: remove))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

/// "Remove from today's review" as an accessibility action, present only
/// while the chip offers removal; SwiftUI has no optional action modifier.
private struct MemoryReviewChipRemoveAction: ViewModifier {
    let remove: (() -> Void)?

    func body(content: Content) -> some View {
        if let remove {
            content.accessibilityAction(named: "Remove from today's review", remove)
        } else {
            content
        }
    }
}

/// The transcript's heading for a source: "now the review turns to this". A
/// full-width row between the verdict on the last source and the first
/// question about the next, so the switch happens where the eye already is
/// rather than as a checkmark far above. Clicking opens the source, the same
/// answer the chip gives to "what did it actually say?".
private struct MemoryReviewSourceTurnRow: View {
    let source: StudioArticle
    let bookCoverPath: String?
    /// This source's place in the day, as (ordinal, count); nil when the
    /// source is not in the strip.
    let position: (Int, Int)?
    let open: () -> Void

    private var positionText: String? {
        guard let position, position.1 > 1 else { return nil }
        return "\(position.0) of \(position.1)"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 18, height: 1)
                SourceThumbnail(source: source, size: 28, bookCoverPath: bookCoverPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now reviewing")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Text(source.title)
                        .zoomedSystemFont(size: 13, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if let positionText {
                    Text(positionText)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensInOtherWindow(source)
        .help("Open \(source.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            positionText.map { "Now reviewing \(source.title), source \($0)" }
                ?? "Now reviewing \(source.title)"
        )
        .accessibilityIdentifier("mac.chatMemorySourceTurn")
    }
}

/// A chat header's trailing control, which works in the titlebar band too
/// (`TitlebarBandButton` there, a hover-washed button in flow): the memory
/// focus chrome's × (`MemoryReviewFocusChrome`).
///
/// Docked, the header hangs in the window's titlebar band, where a SwiftUI
/// `Button` lights up under the pointer but loses its click to the window
/// drag as soon as the pointer moves a pixel between press and release (see
/// `TitlebarBandHitSurfaceView`). The `WindowDragBlocker` under the row does
/// not stop that — the Reader's toolbar gave up the same blocker for the
/// same reason — so in the band this is a `TitlebarBandButton` that owns its
/// press. The pop-out window and fullscreen keep a plain `Button` with the
/// same round wash.
struct ChatHeaderControlButton<Label: View>: View {
    let onTitlebarBand: Bool
    let controlSize: CGFloat
    let help: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    /// How far the wash and the click target reach past the icon's square, the
    /// same on both paths so the control looks and hits identically wherever
    /// the header is mounted.
    private let washInset: CGFloat = 5

    var body: some View {
        if onTitlebarBand {
            TitlebarBandButton(
                help: help,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                washInset: washInset,
                controlSize: controlSize,
                // The in-flow wash is a circle; a radius of half the grown
                // target keeps it one here.
                cornerRadius: (controlSize + washInset * 2) / 2,
                action: action,
                label: label
            )
        } else {
            Button(action: action) {
                label()
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: -washInset, opacity: 0.12))
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

/// The composer's notebook chip, as a button or as the picker's menu: the
/// label with a capsule wash on hover and press. `.menuStyle(.button)` lets
/// a button style draw a Menu's label (`PickerPillButtonStyle`). The canvas's
/// "+N" chip wears it too (`KnowledgeMapChatChipRow`).
struct ComposerChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ComposerChip(isPressed: configuration.isPressed, content: configuration.label)
    }
}

private struct ComposerChip<Content: View>: View {
    let isPressed: Bool
    let content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.primary.opacity(isPressed ? 0.09 : (isHovering ? 0.06 : 0)))
            )
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A walkthrough step's animation, opened large from its row.
