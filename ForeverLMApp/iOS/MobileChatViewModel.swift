import Combine
import Foundation

// A typed or dictated conversation, streamed token by token and optionally read
// back aloud: about one source (the Reader's Ask, a walkthrough's cards), or
// about a notebook's ticked sources (its Chat tab, `MobileNotebookChatContext`).
//
// Distinct from MobileSourceChatService (the Siri hands-free path), which is
// single-shot and answers under a spoken-length budget. Here the user is looking
// at the screen, so answers are prose, keep their markdown, and arrive live.

/// What a notebook chat reads, fixed when it starts (a chat under way keeps
/// the catalog it began with, as on the Mac): the notebook, the ticked
/// sources that fit whole with their text, and the ticked sources it holds
/// but could not load (`MobileNotebookChatGrounding`).
struct MobileNotebookChatContext: Sendable {
    let notebook: MobileCloudNotebook
    let loaded: [MobileNotebookChatPrompt.LoadedSource]
    let notLoaded: [MobileNotebookChatPrompt.UnloadedSource]

    var tickedCount: Int { loaded.count + notLoaded.count }
}

/// A saved notebook chat continued on the phone: which sitting this is, so
/// the turns it adds keep their ids from one save to the next, and how many
/// of the sources the saved chat read are not on this phone.
struct MobileChatContinuation: Equatable, Sendable {
    let sitting: String
    let missingSourceCount: Int
}

struct MobileChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    /// Parsed once, off-main, when the stream ends. Nil while streaming, so the
    /// view renders plain text rather than re-parsing markdown on the render path
    /// every 75 ms for the length of a reply.
    var rendered: AttributedString?
    var figures: [SyncedPaperFigure] = []
    /// Set on a walkthrough step's own turn (walk mode): the id of the step
    /// it plays. Such a turn opens with the `WalkthroughStepTurn` line; the
    /// card is its picture, so it is never drawn as a bubble.
    var walkStepID: String? = nil
}

/// A message sent while a reply was still streaming. It waits outside
/// `messages` — a user turn appended under a streaming reply would be sent as
/// history with the next request — and is sent, in order, once the stream ends.
struct MobileQueuedChatMessage: Identifiable, Equatable {
    let id: UUID
    let text: String
    let selection: MobileReaderSelection?
}

@MainActor
final class MobileChatViewModel: ObservableObject {
    /// Starts `.unknown` because resolving it reads the keychain, which is IPC and
    /// therefore off-main. The composer renders neither itself nor the sign-in
    /// prompt until it resolves, so a signed-in user never sees a one-frame
    /// "sign in" flash.
    enum SignInState: Equatable {
        case unknown
        case signedIn
        case signedOut
    }

    @Published private(set) var messages: [MobileChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isResponding = false
    /// Messages waiting for the streaming reply to finish, oldest first.
    @Published private(set) var queuedMessages: [MobileQueuedChatMessage] = []
    @Published var errorMessage: String?
    /// The passage the user selected in the reader, shown as a chip above the
    /// composer until it is folded into the next message.
    @Published var pendingSelection: MobileReaderSelection?
    @Published private(set) var signInState: SignInState = .unknown
    @Published var speakReplies: Bool {
        didSet {
            guard speakReplies != oldValue else { return }
            let value = speakReplies
            Task.detached(priority: .utility) {
                UserDefaults.standard.set(value, forKey: Self.speakRepliesDefaultsKey)
            }
            if !speakReplies { stopSpeaking() }
        }
    }

    /// The source a reading chat is about; in a notebook chat, the first source
    /// it loaded, which the saved session names first.
    let source: MobileCloudSource
    /// The notebook the chat is filed under (`goalID`): the Reader's Ask
    /// inside a notebook, a walk started in one, and every notebook chat.
    let notebook: MobileCloudNotebook?
    /// A notebook chat's grounding; nil for a chat about one source.
    let notebookContext: MobileNotebookChatContext?
    /// Set when this chat continues a saved one; nil for a new chat.
    let continuation: MobileChatContinuation?
    /// The chat's own model, from its model chip; nil runs on the account's
    /// default chat model. Changing it moves the next turn, not the past ones.
    @Published var modelOverride: MobileChatModelChoice? = nil

    /// Walk mode: the walkthrough whose cards this chat sits under
    /// (walkthrough-design.md, "the deck on the phone"). One chat serves the
    /// whole deck, as on the Mac: each card's conversation is the part of it
    /// after that card's own turn, and the tutor reads every card played so
    /// far. Nil for an ordinary reading chat.
    let walkthrough: PaperWalkthrough?
    /// The card on screen, which a message is about. Set by the deck.
    @Published var currentStepIndex = 0
    /// The learner's Forgot/Remembered on each question card, by step id.
    @Published private(set) var recall: [String: Bool] = [:]
    /// Question cards whose answer has been graded (by the tutor, from a
    /// typed answer, or by the learner's own Forgot/Remembered): the grading
    /// brief rides only the first answer to each.
    private var answeredQuizStepIDs: Set<String> = []

    nonisolated static let speakRepliesDefaultsKey = "ios.readingChat.speakReplies"

    /// One spelling for both ledgers this surface writes: the usage event and
    /// the recorded session must name the same host.
    static let usageProvider = "OpenRouter"

    /// Matches the Mac's stream cadence: deltas coalesce into at most one
    /// main-actor publish per interval instead of one per token.
    private static let streamPublishInterval: TimeInterval = 0.075

    /// Given at init, or later by a walkthrough deck that loads it after
    /// opening (`provideSourceText`); read once, when the prompt is built.
    private var sourceText: String
    /// Built on first send and kept: the prompt cache keys on the exact bytes, so
    /// every turn has to reuse this string rather than rebuild an equal one.
    private var cachedSystemPrompt: String?
    private let onSessionSaveFailure: (@MainActor @Sendable (String) -> Void)?
    /// The chat model a walk is recorded under when none of its turns called
    /// one. A test passes its own: the account's store builds a CKContainer,
    /// which traps in a test host built without code signing.
    private let resolveSaveRoute: @Sendable () async throws -> ResolvedAITextRoute
    nonisolated private static func accountChatRoute() async throws -> ResolvedAITextRoute {
        try await MobileModelPreferenceStore.shared.resolve(.chat)
    }
    private let speech = MobileReviewSpeechService.shared
    /// Fresh per chat: the CloudKit record name is a hash of this id, so reusing
    /// one would upsert and replace the earlier session's exchanges on the Mac.
    /// A continued chat keeps its saved one, and appends instead
    /// (`continuation`).
    let sessionID: String
    private let startedAt = Date()
    private var recordedExchanges: [MobileReviewRecordedExchange] = []
    private var lastResolvedRoute: ResolvedAITextRoute?
    private var sendTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    /// Full-snapshot CloudKit saves are chained so an older turn can never land
    /// after a newer one and truncate the centralized transcript.
    private var sessionSaveTask: Task<Void, Never>?
    private var lastQueuedExchangeCount = 0
    private var isResolvingRouteForSave = false
    private var didFinish = false
    private var shouldSendInitialPrompt = false
    /// The learner's first message, which titles a notebook chat.
    private var firstQuestion: String?

    /// `onSessionSaveFailure` reports into a surface that outlives this chat. The
    /// CloudKit save starts as the sheet is being dismissed, so by the time it can
    /// fail there is no chat left to render the error in.
    init(
        source: MobileCloudSource,
        sourceText: String,
        selection: MobileReaderSelection?,
        initialPrompt: String? = nil,
        walkthrough: PaperWalkthrough? = nil,
        notebook: MobileCloudNotebook? = nil,
        onSessionSaveFailure: (@MainActor @Sendable (String) -> Void)? = nil,
        resolveSaveRoute: @escaping @Sendable () async throws -> ResolvedAITextRoute = MobileChatViewModel.accountChatRoute
    ) {
        self.source = source
        self.notebook = notebook
        self.notebookContext = nil
        self.continuation = nil
        self.sessionID = "ios-\(UUID().uuidString.lowercased())"
        self.walkthrough = walkthrough
        self.pendingSelection = selection
        self.resolveSaveRoute = resolveSaveRoute
        // Deliberately only stored here. init runs inside a @StateObject autoclosure
        // during body evaluation, so neither the prompt build nor the keychain read
        // that resolves signInState may happen on this path.
        self.sourceText = sourceText
        self.onSessionSaveFailure = onSessionSaveFailure
        self.speakReplies = UserDefaults.standard.bool(forKey: Self.speakRepliesDefaultsKey)
        if let initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPrompt.isEmpty {
            self.draft = initialPrompt
            self.shouldSendInitialPrompt = true
        }

        registerWithAudioArbiter()
    }

    /// A notebook chat: grounded in `notebook`'s loaded sources, whole, and
    /// filed under its notebook. nil when no source loaded — a chat with
    /// nothing to read is not offered (the composer says why).
    init?(
        notebook: MobileNotebookChatContext,
        initialPrompt: String?,
        modelOverride: MobileChatModelChoice? = nil,
        onSessionSaveFailure: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        guard let first = notebook.loaded.first else { return nil }
        self.source = first.source
        self.notebook = notebook.notebook
        self.notebookContext = notebook
        self.continuation = nil
        self.sessionID = "ios-\(UUID().uuidString.lowercased())"
        self.walkthrough = nil
        self.pendingSelection = nil
        self.sourceText = first.text
        self.modelOverride = modelOverride
        self.onSessionSaveFailure = onSessionSaveFailure
        self.resolveSaveRoute = Self.accountChatRoute
        self.speakReplies = UserDefaults.standard.bool(forKey: Self.speakRepliesDefaultsKey)
        if let initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPrompt.isEmpty {
            self.draft = initialPrompt
            self.shouldSendInitialPrompt = true
        }
        registerWithAudioArbiter()
    }

    /// A saved notebook chat, continued (`MobileNotebookChatContinuation`):
    /// its transcript as the history every new turn is asked under, grounded
    /// in `notebook` — the sources the saved chat read, whole — and saved by
    /// appending to the same session. `source` is the first of them this
    /// phone holds; with none of their text loaded, the chat shows and cannot
    /// be sent to (the composer says why). Nothing is written until a reply
    /// arrives.
    init(
        continuing sessionID: String,
        messages: [MobileChatMessage],
        source: MobileCloudSource,
        notebook: MobileNotebookChatContext,
        missingSourceCount: Int,
        modelOverride: MobileChatModelChoice? = nil,
        onSessionSaveFailure: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.source = source
        self.notebook = notebook.notebook
        self.notebookContext = notebook
        self.continuation = MobileChatContinuation(
            sitting: UUID().uuidString.lowercased(),
            missingSourceCount: missingSourceCount
        )
        self.sessionID = sessionID
        self.walkthrough = nil
        self.pendingSelection = nil
        self.sourceText = notebook.loaded.first?.text ?? ""
        self.modelOverride = modelOverride
        self.onSessionSaveFailure = onSessionSaveFailure
        self.resolveSaveRoute = Self.accountChatRoute
        self.speakReplies = UserDefaults.standard.bool(forKey: Self.speakRepliesDefaultsKey)
        self.messages = messages
        registerWithAudioArbiter()
        renderSavedReplies()
    }

    /// A saved chat's replies arrive as the text they were saved as; each is
    /// parsed once, off-main, as a reply this phone streamed is, so a Mac
    /// reply's Markdown and visualization read here as they do there.
    private func renderSavedReplies() {
        let saved = messages.filter { $0.role == .assistant && $0.rendered == nil }
        guard !saved.isEmpty else { return }
        Task { [weak self] in
            for message in saved {
                let rendered = await Self.renderMarkdown(message.content)
                guard let self, let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }
                self.messages[index].rendered = rendered
            }
        }
    }

    /// The arbiter drives this when another surface takes the session. Without
    /// it a spoken reply keeps talking into whatever mic was just armed — the
    /// feedback loop the arbiter exists to prevent.
    private func registerWithAudioArbiter() {
        Task { [weak self] in
            await MobileAudioSessionArbiter.shared.register(.readingSpeech) { [weak self] in
                await self?.stopSpeaking()
            }
        }
    }

    /// What the chat is called on screen: its notebook, or its source.
    var title: String {
        notebookContext?.notebook.title ?? source.title
    }

    deinit {
        sendTask?.cancel()
        speakTask?.cancel()
    }

    // MARK: - Lifecycle

    func refreshSignInState() async {
        let signedIn = await Task.detached(priority: .userInitiated) { ManagedAI.isSignedIn }.value
        let resolved: SignInState = signedIn ? .signedIn : .signedOut
        guard resolved != signInState else { return }
        signInState = resolved
    }

    /// Call when the chat is dismissed. Idempotent — `onDisappear` can fire more
    /// than once for one presentation.
    func finish() {
        guard !didFinish else { return }
        didFinish = true
        sendTask?.cancel()
        sendTask = nil
        stopSpeaking()
        // Hand the session back now the surface is gone, so the Voice tab can
        // re-arm its mic without having to preempt us first.
        Task { await MobileAudioSessionArbiter.shared.release(.readingSpeech) }
        queueSessionSnapshotSave(force: true)
    }

    func clearError() {
        errorMessage = nil
    }

    /// Home chat arrives with the first question already committed by the
    /// user. Sending waits for the sheet's lifecycle task so no network or
    /// prompt work runs from a SwiftUI StateObject initializer.
    func sendInitialPromptIfNeeded() {
        guard shouldSendInitialPrompt, signInState == .signedIn else { return }
        shouldSendInitialPrompt = false
        send()
    }

    // MARK: - Composing

    var canSend: Bool {
        // A continued chat none of whose sources loaded has nothing to read.
        guard notebookContext?.loaded.isEmpty != true else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingSelection != nil
    }

    func appendDictatedText(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? spoken : "\(existing) \(spoken)"
    }

    func send() {
        if isResponding {
            // A reply is still streaming: the message waits under it and goes
            // the moment the stream ends, instead of the tap doing nothing.
            enqueueDraft()
            return
        }
        // Earlier sends are still waiting; this one belongs behind them.
        if !queuedMessages.isEmpty {
            enqueueDraft()
            sendNextQueuedMessage()
            return
        }

        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = pendingSelection
        guard sendNow(typed: typed, selection: selection) != nil else { return }
        draft = ""
        pendingSelection = nil
    }

    /// Starts the stream for one message. Leaves the composer alone: a live
    /// send clears it in `send()`, a queued one was never in it. Returns the
    /// id of the reply it opened; nil when there was nothing to send.
    @discardableResult
    private func sendNow(typed: String, selection: MobileReaderSelection?) -> UUID? {
        let contextBlock = selection.map {
            MobileReaderText.contextBlock(selection: $0.text, sourceTitle: source.title)
        } ?? ""
        let visibleContent = typed.isEmpty ? "Explain this passage" : typed
        let providerContent = Self.combinedComposerText(draft: visibleContent, context: contextBlock)
        guard !providerContent.isEmpty else { return nil }
        guard notebookContext?.loaded.isEmpty != true else {
            // A continued chat whose sources' text has not reached the phone.
            errorMessage = "None of this chat's sources has loaded on this iPhone yet."
            return nil
        }
        guard walkthrough == nil || hasSourceText else {
            // A walkthrough's chat opens before its text has loaded; the
            // tutor answers from the source, so it waits for it.
            errorMessage = "The source's text is still loading. Try again in a moment."
            return nil
        }

        errorMessage = nil
        stopSpeaking()

        // Walk mode: the card on screen joins the chat first, so the message
        // and its reply belong to it and the tutor reads the card's words
        // right above the question; the first answer to a question card
        // carries the grading brief, so the reply is the grade.
        var modelContent = providerContent
        if walkthrough != nil {
            bringCardIntoChat()
            if let grading = takeGradingContext() {
                modelContent += "\n\n" + grading
            }
        }

        messages.append(MobileChatMessage(id: UUID(), role: .user, content: visibleContent, isStreaming: false))

        var history = messages.dropLast().map { (role: $0.role.rawValue, content: Self.modelContent(of: $0)) }
        history.append((role: MobileChatMessage.Role.user.rawValue, content: modelContent))
        let assistantID = UUID()
        messages.append(MobileChatMessage(id: assistantID, role: .assistant, content: "", isStreaming: true))
        isResponding = true

        // The Mac shows this as the learner's message, so it records what the
        // user actually said rather than the quoted passage wrapped around it.
        let question = visibleContent
        if firstQuestion == nil { firstQuestion = question }

        sendTask = Task { [weak self] in
            await self?.runStream(
                assistantID: assistantID,
                history: history,
                question: question,
                restoringDraft: typed,
                restoringSelection: selection
            )
        }
        return assistantID
    }

    // MARK: - Walk mode

    /// The source's text, for a chat opened before it was loaded. Ignored
    /// once the prompt has been built from text already given.
    func provideSourceText(_ text: String) {
        guard cachedSystemPrompt == nil else { return }
        sourceText = text
    }

    var hasSourceText: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the chat under the card on screen shows: that card's own
    /// conversation — the messages after one of its turns and before the
    /// next card's — and never a step turn itself, the card being its
    /// picture (the Mac's `WalkthroughTranscriptFold.cardThread`). An
    /// ordinary chat shows every message.
    var displayedMessages: [MobileChatMessage] {
        guard let walkthrough, walkthrough.steps.indices.contains(currentStepIndex) else { return messages }
        let current = walkthrough.steps[currentStepIndex].id
        var owner: String?
        var thread: [MobileChatMessage] = []
        for message in messages {
            if let stepID = message.walkStepID {
                owner = stepID
                continue
            }
            if owner == current { thread.append(message) }
        }
        return thread
    }

    /// The card on screen's step, when this chat plays a walk.
    var currentStep: PaperWalkthroughStep? {
        guard let walkthrough, walkthrough.steps.indices.contains(currentStepIndex) else { return nil }
        return walkthrough.steps[currentStepIndex]
    }

    /// Appends the card on screen's turn unless the newest step turn in the
    /// chat is already its own (the Mac's `bringWalkthroughCardIntoChat`).
    /// The turn is the Mac's own Markdown (`WalkthroughStepComposer`), saved
    /// as a step exchange, so the Mac reopens this chat as the walk.
    private func bringCardIntoChat() {
        guard let walkthrough, let step = currentStep else { return }
        let newest = messages.last(where: { $0.walkStepID != nil })?.walkStepID
        guard newest != step.id else { return }
        let marker = WalkthroughStepTurn.Marker(
            sourceID: source.id,
            stepID: step.id,
            index: currentStepIndex,
            count: walkthrough.steps.count
        )
        let markdown = WalkthroughStepComposer.markdown(step: step, marker: marker, lens: nil)
        messages.append(MobileChatMessage(
            id: UUID(),
            role: .assistant,
            content: markdown,
            isStreaming: false,
            walkStepID: step.id
        ))
        recordedExchanges.append(
            MobileReviewRecordedExchange(
                question: markdown,
                userAnswer: "",
                evaluation: nil,
                score: nil,
                answeredAt: Date()
            )
        )
    }

    /// The grading brief for the card on screen, once: when it asks a
    /// question nobody has graded yet.
    private func takeGradingContext() -> String? {
        guard let walkthrough, let step = currentStep, let quiz = step.quiz, quiz.isValid,
              !answeredQuizStepIDs.contains(step.id) else { return nil }
        answeredQuizStepIDs.insert(step.id)
        let marker = WalkthroughStepTurn.Marker(
            sourceID: source.id,
            stepID: step.id,
            index: currentStepIndex,
            count: walkthrough.steps.count
        )
        return WalkthroughStepComposer.gradingContext(step: step, quiz: quiz, marker: marker)
    }

    /// The learner's own grade on the card on screen's question, after
    /// Show Answer: saved as an exchange of the chat with score 1 or 0 and
    /// no model call, exactly as the Mac saves it (`gradeWalkthroughRecall`).
    func gradeRecall(remembered: Bool) {
        guard let step = currentStep, let quiz = step.quiz else { return }
        gradeRecall(
            remembered: remembered,
            line: remembered ? "I had it." : "I didn't have it.",
            record: WalkthroughStepComposer.recallRecord(quiz: quiz, remembered: remembered),
            score: remembered ? 1 : 0
        )
    }

    /// A Find it answered on the figure: the panel picked, saved as the
    /// recall grades are (`ReviewSessionManager.pickWalkthroughPanel`).
    func gradeFind(picked: String, correct: Bool, firstTry: Bool) {
        guard let step = currentStep, let quiz = step.quiz else { return }
        gradeRecall(
            remembered: correct,
            line: "Panel \(PaperWalkthroughValidation.panelDisplayName(picked))",
            record: WalkthroughStepComposer.findRecord(quiz: quiz, picked: picked, correct: correct),
            score: correct ? (firstTry ? 1 : 0.5) : 0
        )
    }

    private func gradeRecall(remembered: Bool, line: String, record: String, score: Double) {
        guard walkthrough != nil, let step = currentStep, step.quiz != nil, recall[step.id] == nil else { return }
        bringCardIntoChat()
        answeredQuizStepIDs.insert(step.id)
        recall[step.id] = remembered
        messages.append(MobileChatMessage(id: UUID(), role: .user, content: line, isStreaming: false))
        let replyID = UUID()
        messages.append(MobileChatMessage(id: replyID, role: .assistant, content: record, isStreaming: false))
        Task { [weak self] in
            let rendered = await Self.renderMarkdown(record)
            guard let self, let index = self.messages.firstIndex(where: { $0.id == replyID }) else { return }
            self.messages[index].rendered = rendered
        }
        recordedExchanges.append(
            MobileReviewRecordedExchange(
                question: "",
                userAnswer: line,
                evaluation: record,
                score: score,
                answeredAt: Date()
            )
        )
        queueSessionSnapshotSave(force: true)
    }

    #if DEBUG
    /// The exchanges the next session save carries, for the iOS unit tests.
    var recordedExchangesForTesting: [MobileReviewRecordedExchange] { recordedExchanges }
    #endif

    /// What the model reads of a message: a step turn without its step line,
    /// and a reply a continued chat read back without the lines the Mac keeps
    /// at its head for its pages and saved cards
    /// (`MobileChatTranscriptTurns.modelLine`).
    private static func modelContent(of message: MobileChatMessage) -> String {
        let content = message.walkStepID == nil ? message.content : WalkthroughStepTurn.stripped(message.content)
        return message.role == .assistant ? MobileChatTranscriptTurns.modelLine(content) : content
    }

    // MARK: - Queued messages

    private func enqueueDraft() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = pendingSelection
        guard !typed.isEmpty || selection != nil else { return }
        queuedMessages.append(MobileQueuedChatMessage(id: UUID(), text: typed, selection: selection))
        draft = ""
        pendingSelection = nil
    }

    /// The oldest waiting message becomes the next send. Called when a stream
    /// ends well; a failed stream leaves the queue waiting under the error.
    private func sendNextQueuedMessage() {
        guard !isResponding, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        sendNow(typed: next.text, selection: next.selection)
    }

    /// The × on a queued bubble: its words go back into the composer, ahead of
    /// anything typed since, and its passage becomes the pending one again.
    func returnQueuedMessageToDraft(_ id: UUID) {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        let item = queuedMessages.remove(at: index)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? item.text : "\(item.text)\n\(typed)"
        if pendingSelection == nil { pendingSelection = item.selection }
    }

    // MARK: - Streaming

    private func runStream(
        assistantID: UUID,
        history: [(role: String, content: String)],
        question: String,
        restoringDraft: String,
        restoringSelection: MobileReaderSelection?
    ) async {
        let batcher = MobileChatStreamBatcher(interval: Self.streamPublishInterval) { [weak self] text in
            await self?.applyStreamedText(text, to: assistantID)
        }

        do {
            let system = await resolvedSystemPrompt()
            let result = try await MobileStreamingChat.stream(
                system: system,
                messages: history,
                modelOverride: modelOverride?.preference
            ) { delta in
                await batcher.consume(delta)
            }

            try MobileOpenRouterChat.requireSelectedModel(
                report: result.report ?? .empty,
                route: result.route
            )
            lastResolvedRoute = result.route

            // A notebook chat's prompt carries no figure catalog, so no
            // figure id can be named in its reply.
            let presentation = Self.figurePresentation(
                from: result.text,
                catalog: notebookContext == nil ? source.paperFigures : []
            )
            let rendered = await Self.renderMarkdown(presentation.text)
            finishStream(
                assistantID: assistantID,
                text: presentation.text,
                rendered: rendered,
                figures: presentation.figures
            )

            // The Mac's chat exchange (`ReviewSessionManager`, a chat that is
            // not a review): no tutor question, the learner's message as the
            // answer, the reply as the evaluation — in a walk, the answer to
            // the step turn before it, so a walk begun here reopens there as
            // the same chat. Older builds put a reading chat's message where
            // the tutor's question goes, which the Mac drew as the tutor
            // speaking and never counted as the learner's turn. Ungraded:
            // nothing here tested anyone.
            recordedExchanges.append(
                MobileReviewRecordedExchange(
                    question: "",
                    userAnswer: question,
                    evaluation: presentation.text,
                    score: nil,
                    answeredAt: Date()
                )
            )
            queueSessionSnapshotSave()

            if speakReplies { speak(presentation.text) }
            // A message sent while this reply streamed goes now, as its own turn.
            sendNextQueuedMessage()
        } catch {
            isResponding = false
            removeMessage(assistantID)

            // A cancelled send is a dismissal, not a failure.
            guard !Task.isCancelled else { return }

            // Drop the orphaned user turn and hand its text back to the composer:
            // the transcript stays strictly alternating for the next request, and
            // a retry is one tap. The real error is surfaced verbatim — never
            // substitute an answer of our own (CLAUDE.md).
            removeTrailingUserMessage()
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = restoringDraft
            }
            if pendingSelection == nil {
                pendingSelection = restoringSelection
            }
            if let chatError = error as? MobileStreamingChatError, case .notSignedIn = chatError {
                // The session aged out mid-chat; swap the composer for the
                // sign-in prompt rather than letting the next tap fail too.
                signInState = .signedOut
            }
            errorMessage = error.localizedDescription
        }
    }

    private func applyStreamedText(_ text: String, to assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content = text
    }

    private func finishStream(
        assistantID: UUID,
        text: String,
        rendered: AttributedString,
        figures: [SyncedPaperFigure]
    ) {
        isResponding = false
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        // Mutate content in place rather than replacing the element: the message
        // identity has to survive the stream→final transition or SwiftUI tears the
        // row down and rebuilds it, which is what makes streamed text flash.
        messages[index].content = text
        messages[index].rendered = rendered
        messages[index].figures = figures
        messages[index].isStreaming = false
    }

    /// Parses the model-facing machine marker, never human-authored text. The
    /// stable figure ID comes from the catalog; unknown IDs are simply omitted
    /// rather than being allowed to address another source or file.
    private nonisolated static func figurePresentation(
        from response: String,
        catalog: [SyncedPaperFigure]
    ) -> (text: String, figures: [SyncedPaperFigure]) {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        guard let regex = try? NSRegularExpression(pattern: #"\[\[figure:([^\]]+)\]\]"#) else {
            return (response, [])
        }
        let range = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = regex.matches(in: response, range: range)
        var figures: [SyncedPaperFigure] = []
        var seen: Set<String> = []
        for match in matches where match.numberOfRanges == 2 {
            guard let idRange = Range(match.range(at: 1), in: response) else { continue }
            let id = String(response[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(id).inserted, let figure = byID[id] { figures.append(figure) }
        }
        let stripped = regex.stringByReplacingMatches(in: response, range: range, withTemplate: "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, figures)
    }

    /// Inline-only parsing keeps the line and paragraph breaks that full markdown
    /// parsing would collapse into a single run, while still rendering emphasis,
    /// code spans and links. A malformed run falls back to the raw text — a chat
    /// reply is never worth dropping over its formatting.
    ///
    /// Off-main and once per reply: in the view body it would re-parse the whole
    /// partial answer on every streamed publish.
    private nonisolated static func renderMarkdown(_ markdown: String) async -> AttributedString {
        await Task.detached(priority: .userInitiated) {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let shown = replacingVisualizations(in: markdown)
            return (try? AttributedString(markdown: shown, options: options)) ?? AttributedString(shown)
        }.value
    }

    /// The line a reply's visualization shows as here. A Mac chat can draw one
    /// (`Prompts.chatVisualization`): a fenced block whose language is
    /// `visualization`, holding an HTML document the Mac runs in a frame. This
    /// phone draws chat as text, so a saved Mac chat continued here would
    /// otherwise show the program's source. A visualization fence inside
    /// another code block is that block's text. Mirrors `splitVisualizations`
    /// in the chat renderer.
    nonisolated static let visualizationStandIn = "*Interactive visualization · runs in the Mac app*"

    nonisolated static func replacingVisualizations(in markdown: String) -> String {
        guard markdown.range(of: "visualization", options: .caseInsensitive) != nil else { return markdown }
        func fence(_ line: Substring) -> (marker: Character, length: Int, rest: Substring)? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            guard indent.count <= 3 else { return nil }
            let body = line.dropFirst(indent.count)
            guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
            let run = body.prefix { $0 == marker }
            guard run.count >= 3 else { return nil }
            return (marker, run.count, body.dropFirst(run.count))
        }
        func closes(_ line: Substring, _ open: (marker: Character, length: Int)) -> Bool {
            guard let candidate = fence(line) else { return false }
            return candidate.marker == open.marker && candidate.length >= open.length
                && candidate.rest.allSatisfy { $0 == " " || $0 == "\t" }
        }
        var output: [Substring] = []
        var outer: (marker: Character, length: Int)?
        var inVisualization: (marker: Character, length: Int)?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = inVisualization {
                if closes(line, open) { inVisualization = nil }
                continue
            }
            if let open = outer {
                if closes(line, open) { outer = nil }
                output.append(line)
                continue
            }
            guard let opener = fence(line) else {
                output.append(line)
                continue
            }
            if opener.rest.trimmingCharacters(in: .whitespaces).lowercased() == "visualization" {
                inVisualization = (opener.marker, opener.length)
                output.append(Substring(visualizationStandIn))
            } else {
                outer = (opener.marker, opener.length)
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private func removeMessage(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private func removeTrailingUserMessage() {
        guard messages.last?.role == .user else { return }
        messages.removeLast()
    }

    // MARK: - Spoken replies

    private func speak(_ text: String) {
        speakTask?.cancel()
        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Half-duplex is mandatory: taking the lease preempts the Voice
                // tab so its mic tap is torn down before the synthesizer starts.
                // Two live owners means recognition transcribes our own reply and
                // routes it back in as a user utterance.
                try await MobileAudioSessionArbiter.shared.acquire(.readingSpeech, for: .playback)
            } catch {
                self.errorMessage = "Spoken replies could not start: \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled else { return }
            // speak() runs the reply through MobileReviewSpeechService.spokenText,
            // the markdown/citation stripper, so narration loses the markup while
            // the transcript on screen keeps it.
            self.speech.speak(text, owner: .readingChat)
        }
    }

    private func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        // Owner-scoped: the synthesizer is shared, so an unqualified stop here
        // would cut off a Voice-tab review that happens to be speaking.
        speech.stop(owner: .readingChat)
        // The lease is deliberately kept: it belongs to this surface for as long
        // as the chat is open. The composer's dictation holds a different lease
        // and preempts this one through the arbiter when it arms the mic.
    }

    /// A reply's ⋯ › Read Aloud: that one reply, whether or not every reply
    /// is read as it lands (`speakReplies`).
    func readAloud(_ message: MobileChatMessage) {
        guard message.role == .assistant, !message.content.isEmpty else { return }
        speak(message.content)
    }

    /// A reply's ⋯ › Stop Reading Aloud.
    func stopReadingAloud() {
        stopSpeaking()
    }

    // MARK: - Session recording

    private func queueSessionSnapshotSave(force: Bool = false) {
        guard !recordedExchanges.isEmpty,
              force || recordedExchanges.count > lastQueuedExchangeCount else { return }
        guard let lastResolvedRoute else {
            // A walk whose only turns so far are the learner's own
            // Forgot/Remembered called no model; the chat's model is still
            // the one the session is recorded under.
            guard walkthrough != nil, !isResolvingRouteForSave else { return }
            isResolvingRouteForSave = true
            Task { [weak self, resolveSaveRoute] in
                let route = try? await resolveSaveRoute()
                guard let self else { return }
                self.isResolvingRouteForSave = false
                guard let route else { return }
                if self.lastResolvedRoute == nil { self.lastResolvedRoute = route }
                self.queueSessionSnapshotSave(force: true)
            }
            return
        }
        lastQueuedExchangeCount = recordedExchanges.count

        if let continuation {
            queueContinuationSave(continuation, model: lastResolvedRoute.model)
            return
        }

        let count = recordedExchanges.count
        let isWalk = walkthrough != nil
        let topic: String
        let summary: String
        let knowledgeNote: String
        if let notebookContext {
            // A notebook holds many chats, so each is called by what it was
            // first asked rather than by the notebook's name.
            topic = MobileNotebookChatPrompt.chatTitle(firstQuestion: firstQuestion, fallback: notebookContext.notebook.title)
            summary = "Notebook chat in \(notebookContext.notebook.title) on iOS — \(count) question\(count == 1 ? "" : "s") about \(notebookContext.loaded.count) source\(notebookContext.loaded.count == 1 ? "" : "s")."
            knowledgeNote = "Recorded from a notebook chat on iOS."
        } else if isWalk {
            topic = source.title
            summary = "Walkthrough of \(source.title) on iOS — \(count) turn\(count == 1 ? "" : "s")."
            knowledgeNote = "Recorded from a walkthrough on iOS."
        } else {
            topic = source.title
            summary = "Reading chat about \(source.title) — \(count) question\(count == 1 ? "" : "s") asked while reading on iOS."
            knowledgeNote = "Recorded from a reading chat on iOS."
        }
        var result = MobileReviewResult(
            sessionID: sessionID,
            topic: topic,
            sourceID: source.id,
            // Filed under its notebook, so the Mac lists it there and opens it
            // in the notebook's workspace.
            goalID: notebook?.id,
            startedAt: startedAt,
            endedAt: Date(),
            // Deliberately ungraded. This score feeds the Mac's memoryReviewStats
            // as the source's most recent recall score, and a reading chat never
            // tested the user — inventing a number here would be exactly the
            // heuristic grading CLAUDE.md forbids.
            overallScore: nil,
            summary: summary,
            exchanges: recordedExchanges,
            gaps: [],
            knowledgeNote: knowledgeNote,
            modelProvider: MobileChatViewModel.usageProvider,
            modelID: lastResolvedRoute.model
        )
        result.kind = isWalk ? .walkthrough : .chat
        // The notebook chat's catalog: every source it read, the first one
        // first (`MobileReviewResult.additionalSourceIDs`). A source it could
        // not load was not read, so it is not named.
        if let notebookContext {
            result.additionalSourceIDs = notebookContext.loaded.dropFirst().map(\.source.id)
        }

        // A completed turn should reach the Mac without waiting for dismissal.
        // Chain snapshots in order, but do not retain the view model: home chats
        // may disappear while their final CloudKit write is still in flight.
        let previousSave = sessionSaveTask
        let report = onSessionSaveFailure
        sessionSaveTask = Task {
            await previousSave?.value
            do {
                try await MobileReviewSessionRecorder.shared.record(result)
            } catch {
                let message = "This chat could not be saved to your Mac yet: \(error.localizedDescription)"
                await MainActor.run { report?(message) }
            }
        }
    }

    /// A continued chat's save: every turn this sitting added, appended to
    /// the saved session after the turns it already holds
    /// (`MobileReviewSessionRecorder.appendChatExchanges`). Each save carries
    /// the whole sitting under the same ids, so a later one replaces an
    /// earlier one's turns rather than adding them twice; the title, the
    /// sources and every turn from before stay the saved chat's own.
    private func queueContinuationSave(_ continuation: MobileChatContinuation, model: String) {
        let added = recordedExchanges.enumerated().map { offset, exchange in
            MobileNotebookChatContinuation.AddedExchange(
                id: MobileNotebookChatContinuation.exchangeID(
                    sessionID: sessionID,
                    sitting: continuation.sitting,
                    index: offset + 1
                ),
                userAnswer: exchange.userAnswer,
                evaluation: exchange.evaluation,
                answeredAt: exchange.answeredAt
            )
        }
        let append = MobileReviewChatAppend(
            sessionID: sessionID,
            exchanges: added,
            knowledgeNote: "Recorded from a notebook chat on iOS.",
            modelProvider: MobileChatViewModel.usageProvider,
            modelID: model,
            endedAt: Date()
        )
        let previousSave = sessionSaveTask
        let report = onSessionSaveFailure
        sessionSaveTask = Task {
            await previousSave?.value
            do {
                try await MobileReviewSessionRecorder.shared.appendChatExchanges(append)
            } catch {
                let message = "This chat could not be saved to your Mac yet: \(error.localizedDescription)"
                await MainActor.run { report?(message) }
            }
        }
    }

    // MARK: - Prompt

    /// Builds the provider-only turn: the visible question first, then the
    /// selected passage that stays out of the learner's transcript bubble.
    private static func combinedComposerText(draft: String, context: String) -> String {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return trimmedContext }
        guard !trimmedContext.isEmpty else { return trimmedDraft }
        return "\(trimmedDraft)\n\(trimmedContext)"
    }

    /// Built off the main actor on first send. The source text runs to 240k
    /// characters, so bounding and interpolating it is real work that stays out
    /// of init, which is on the render path before the sheet has drawn a frame.
    private func resolvedSystemPrompt() async -> String {
        if let cachedSystemPrompt { return cachedSystemPrompt }
        let source = self.source
        let sourceText = self.sourceText
        let notebookContext = self.notebookContext
        let prompt = await Task.detached(priority: .userInitiated) {
            if let notebookContext {
                // Every loaded source whole; the ones it holds and could not
                // load, by name (`MobileNotebookChatPrompt`).
                return MobileNotebookChatPrompt.system(
                    notebookTitle: notebookContext.notebook.title,
                    instructions: notebookContext.notebook.instructions,
                    loaded: notebookContext.loaded,
                    notLoaded: notebookContext.notLoaded
                )
            }
            return Self.systemPrompt(source: source, sourceText: sourceText)
        }.value
        cachedSystemPrompt = prompt
        return prompt
    }

    /// The source text lives in the *system* prompt on purpose. MobileOpenRouterChat
    /// marks messages[0] with cache_control ephemeral ttl 1h for anthropic/* slugs,
    /// so putting the source there means it is written to the prompt cache once and
    /// read back on every later turn instead of being re-billed as fresh input.
    private nonisolated static func systemPrompt(source: MobileCloudSource, sourceText: String) -> String {
        let text = String(sourceText.prefix(MobileStreamingChat.maxSourceCharacters))
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let figureCatalog = source.paperFigures.compactMap { figure -> String? in
            guard let analysis = figure.analysis else { return nil }
            let panels = analysis.panels.map { "\($0.label): \($0.explanation)" }.joined(separator: " | ")
            return "ID=\(figure.id); LABEL=\(figure.figureLabel); PAGE=\(figure.pageNumber); CAPTION=\(figure.caption); VISUAL=\(analysis.summary)\(panels.isEmpty ? "" : "; PANELS=\(panels)")"
        }.joined(separator: "\n")

        return """
        You are a reading companion inside ForeverLM. The user is reading the source below on an iPhone or iPad and is asking you about it while they read.

        How to answer:
        - The source text below is your material. Answer from it.
        - If the source does not cover what was asked, say so plainly — "the source doesn't cover that" — and stop there, or answer from general knowledge only after clearly labelling it as outside the source. Never invent detail and never attribute anything to the source that is not in it.
        - Be concise but complete: answer the actual question first, then add only the context that earns its place. Do not pad, do not restate the question, do not offer a summary the user did not ask for.
        - Quote the source only when the exact wording carries the point.
        - A message may include a passage quoted with "> " — that is the text the user is looking at right now, and the question is about that passage.
        - Markdown is rendered, so use it where it helps readability.
        - If the question concerns a catalogued figure, explain it from the visual analysis and put
          [[figure:ID]] on its own line after the relevant paragraph. Use only an exact ID from the
          figure catalog. This marker displays the original PDF figure and is removed before narration.

        Source title: \(title.isEmpty ? "Untitled" : title)
        Source type: \(canonicalSourceType(source.sourceType))

        --- BEGIN FIGURE CATALOG ---
        \(figureCatalog.isEmpty ? "No vision-analyzed figures are available yet." : figureCatalog)
        --- END FIGURE CATALOG ---

        --- BEGIN SOURCE TEXT ---
        \(text)
        --- END SOURCE TEXT ---
        """
    }
}

/// Coalesces stream deltas so the main actor publishes at most once per interval
/// rather than once per token. `accumulated` is always the full text so far, so a
/// skipped publish is self-healing rather than a lost fragment.
///
/// Unlike the Mac's batcher this awaits each publish, which is what keeps them in
/// order — no sequence guard is needed on the receiving side.
actor MobileChatStreamBatcher {
    private let interval: TimeInterval
    private let publish: @Sendable (String) async -> Void
    private var accumulated = ""
    private var lastPublishedAt = Date.distantPast

    init(interval: TimeInterval, publish: @escaping @Sendable (String) async -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func consume(_ delta: String) async {
        accumulated += delta
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= interval else { return }
        lastPublishedAt = now
        await publish(accumulated)
    }
}
