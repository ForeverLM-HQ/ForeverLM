import SwiftUI

/// A notebook's chat state on the phone, owned by its screen so a tab switch
/// never loses it: what a new chat would read (the ticked sources, whole,
/// loaded off the main actor), the chat under way — new, or a saved one
/// continued — and the model it runs on.
@MainActor
final class MobileNotebookChatSession: ObservableObject {
    enum Grounding {
        case idle
        case preparing
        case ready(MobileNotebookChatContext, MobileNotebookChatGrounding.Plan)
    }

    @Published private(set) var grounding: Grounding = .idle
    /// The chat under way; nil shows the notebook's guide and an empty composer.
    @Published private(set) var chat: MobileChatViewModel?
    @Published var draft = ""
    @Published private(set) var modelChoices: [MobileChatModelChoice] = []
    @Published private(set) var defaultModel: MobileChatModelChoice?
    @Published private(set) var modelError: String?
    /// The model the next chat starts on; nil is the account's default.
    @Published var nextChatModel: MobileChatModelChoice?
    @Published var saveError: String?

    /// What the current grounding was prepared for: the notebook and its
    /// ticked sources in order.
    private var preparedKey: String?
    private var preparation: Task<Void, Never>?
    private var hasLoadedModels = false

    /// Loads, off the main actor, the text of each ticked source in the
    /// notebook's order, stopping at no source: one that does not fit beside
    /// the ones before it is passed over whole, one certainly too long by its
    /// word count is not even downloaded, one whose text is missing is listed
    /// as such (`MobileNotebookChatGrounding`). Nothing is ever cut.
    func prepare(notebook: MobileCloudNotebook, ticked: [MobileCloudSource]) {
        let key = ([notebook.id, notebook.title, notebook.instructions ?? ""] + ticked.map(\.id)).joined(separator: "\u{1F}")
        guard key != preparedKey else { return }
        preparedKey = key
        preparation?.cancel()
        grounding = .preparing
        preparation = Task { [weak self] in
            // Measuring a 240,000-character source is real work: the whole
            // reading runs detached, and stops when a newer tick replaces it.
            let reading = Task.detached(priority: .userInitiated) {
                await Self.ground(notebook: notebook, ticked: ticked)
            }
            let grounded = await withTaskCancellationHandler {
                await reading.value
            } onCancel: {
                reading.cancel()
            }
            guard let grounded, !Task.isCancelled, let self, self.preparedKey == key else { return }
            self.grounding = .ready(grounded.context, grounded.plan)
        }
    }

    /// The ticked sources' text, whole, while it fits; nil when cancelled.
    /// The voice conversation grounds a spoken notebook chat through here too.
    nonisolated static func ground(
        notebook: MobileCloudNotebook,
        ticked: [MobileCloudSource]
    ) async -> (context: MobileNotebookChatContext, plan: MobileNotebookChatGrounding.Plan)? {
        let budget = MobileNotebookChatGrounding.characterBudget
        var remaining = budget
        var candidates: [MobileNotebookChatGrounding.Candidate] = []
        var texts: [String: String] = [:]
        for source in ticked {
            if Task.isCancelled { return nil }
            // A source marked paywalled synced no text (the Reader says so).
            if source.isPaywalled {
                candidates.append(.init(sourceID: source.id, characterCount: nil))
                continue
            }
            if MobileNotebookChatGrounding.certainlyExceeds(wordCount: source.wordCount, remaining: remaining) {
                candidates.append(.init(
                    sourceID: source.id,
                    characterCount: MobileNotebookChatGrounding.minimumCharacters(wordCount: source.wordCount ?? 0)
                ))
                continue
            }
            do {
                let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
                let count = text.count
                candidates.append(.init(sourceID: source.id, characterCount: count))
                if count <= remaining {
                    remaining -= count
                    texts[source.id] = text
                }
            } catch {
                candidates.append(.init(sourceID: source.id, characterCount: nil))
            }
        }
        if Task.isCancelled { return nil }
        let plan = MobileNotebookChatGrounding.plan(candidates, budget: budget)
        let byID = Dictionary(ticked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let context = MobileNotebookChatContext(
            notebook: notebook,
            loaded: plan.loaded.compactMap { id in
                guard let source = byID[id], let text = texts[id] else { return nil }
                return MobileNotebookChatPrompt.LoadedSource(source: source, text: text)
            },
            notLoaded: plan.notLoaded.compactMap { item in
                byID[item.sourceID].map { MobileNotebookChatPrompt.UnloadedSource(source: $0, reason: item.reason) }
            }
        )
        return (context, plan)
    }

    /// Reads, once a screen, the models a chat may pick.
    func loadModelsIfNeeded() async {
        guard !hasLoadedModels else { return }
        hasLoadedModels = true
        do {
            let offered = try await MobileModelPreferenceStore.shared.offeredChatModels()
            modelChoices = offered.choices
            defaultModel = offered.defaultChoice
            modelError = nil
        } catch {
            hasLoadedModels = false
            modelError = error.localizedDescription
        }
    }

    var readyContext: MobileNotebookChatContext? {
        if case .ready(let context, _) = grounding { return context }
        return nil
    }

    var plan: MobileNotebookChatGrounding.Plan? {
        if case .ready(_, let plan) = grounding { return plan }
        return nil
    }

    /// Starts a notebook chat on the draft: the grounding as it stands, the
    /// model picked for it. False when there is nothing to read yet.
    @discardableResult
    func startChat() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context = readyContext,
              let chat = MobileChatViewModel(
                notebook: context,
                initialPrompt: text,
                modelOverride: nextChatModel,
                onSessionSaveFailure: { [weak self] message in self?.saveError = message }
              ) else { return false }
        draft = ""
        opening?.cancel()
        opening = nil
        openingChatID = nil
        openError = nil
        self.chat = chat
        return true
    }

    /// Back to the notebook's guide; the chat under way keeps what it saved.
    func closeChat() {
        opening?.cancel()
        opening = nil
        openingChatID = nil
        chat?.finish()
        chat = nil
    }

    /// The saved chat being read back to be continued; nil when none is.
    @Published private(set) var openingChatID: String?
    /// Why the last saved chat could not be opened to continue.
    @Published private(set) var openError: String?
    private var opening: Task<Void, Never>?

    /// Continues a saved chat of the notebook in place of the one under way
    /// (`MobileNotebookChatContinuation`): its transcript, read from the
    /// catalog, under a composer whose sends append to the same saved
    /// session, reading the sources the saved chat read (`sources`, the ones
    /// this phone holds, in its order) whole, as a new chat reads the ticked
    /// ones. Its model chip starts on the model it last ran on when the
    /// learner offers that one. Opening writes nothing; the first reply does.
    func continueChat(
        _ summary: MobileNotebookChatSummary,
        notebook: MobileCloudNotebook,
        sources: [MobileCloudSource],
        missingSourceCount: Int,
        transcript: @escaping @MainActor () async -> MobileVoiceChatTranscript?
    ) {
        // The chat on screen, or the one on its way there, stays.
        guard chat?.sessionID != summary.id, openingChatID != summary.id else { return }
        closeChat()
        openError = nil
        guard let first = sources.first else { return }
        openingChatID = summary.id
        opening = Task { [weak self] in
            let reading = Task.detached(priority: .userInitiated) {
                await Self.ground(notebook: notebook, ticked: sources)
            }
            let saved = await transcript()
            let grounded = await withTaskCancellationHandler {
                await reading.value
            } onCancel: {
                reading.cancel()
            }
            guard let self, !Task.isCancelled, self.openingChatID == summary.id else { return }
            await self.loadModelsIfNeeded()
            guard !Task.isCancelled, self.openingChatID == summary.id, self.chat == nil else { return }
            self.openingChatID = nil
            self.opening = nil
            guard let saved, !saved.messages.isEmpty, let grounded else {
                self.openError = "This chat is no longer on this iPhone."
                return
            }
            self.chat = MobileChatViewModel(
                continuing: summary.id,
                messages: saved.messages,
                source: grounded.context.loaded.first?.source ?? first,
                notebook: grounded.context,
                missingSourceCount: missingSourceCount,
                modelOverride: summary.modelID.flatMap { model in
                    self.modelChoices.first { $0.preference.model == model }
                },
                onSessionSaveFailure: { [weak self] message in self?.saveError = message }
            )
        }
    }
}

/// Quiz me on it: a spoken review of what the notebook's chat reads — the
/// voice conversation on its ticked sources, the context notebooks put in
/// included, that opens with the tutor's first question, filed under the
/// notebook. The Studio's Review me starts the same conversation.
@MainActor
enum MobileNotebookReviewMe {
    static func start(notebook: MobileCloudNotebook, selection: MobileNotebookChatSelectionStore) {
        let ticked = selection.chatSourceIDs(of: notebook)
        Task { await MobileVoiceConversationController.shared.startReview(notebook: notebook.narrowed(toSourceIDs: ticked)) }
    }
}

/// A notebook's Chat tab: with no chat open, the notebook's guide (the Mac's
/// `NotebookChatGuide`) and its latest chats; else the chat under way — new,
/// or a saved one continued — over one composer, ChatGPT's and the Mac's
/// (2026-10-06): "Ask about <notebook>…", "+" (the chat's sources, Add
/// Sources), the chat's model, dictation, and Talk (the same chat by voice,
/// turn by turn) while the field is empty or send once it is not. A chat
/// reads the ticked sources whole; when they do not all fit, a line over the
/// composer says how many it reads. The toolbar holds the notebook's chats
/// and, while a chat is open, New Chat (the conversation's own bar, with
/// "‹ Chats", Copy and a speaker, went the same day).
struct MobileNotebookChatTab: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var selection: MobileNotebookChatSelectionStore
    @ObservedObject var session: MobileNotebookChatSession
    @Binding var hidesTabBar: Bool
    /// The notebook's Add sources sheet, for an empty notebook's guide.
    let onAddSources: () -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @ObservedObject private var live = MobileVoiceConversationController.shared
    @State private var showsChatHistory = false
    @State private var showsChatSources = false

    /// What a new chat reads, as sources the phone has, in the chats' order:
    /// the notebook's own ticked sources, then the ticked sources of each
    /// context notebook put in. Before the rows are read, its own sources.
    private var tickedSources: [MobileCloudSource] {
        let own = vm.notebookSources(in: notebook)
        guard let board = selection.board(for: notebook) else { return own }
        return board.chatSources(own: own, groups: vm.contextNotebookGroups(in: notebook))
    }

    private var groundingKey: String {
        guard selection.isLoaded else { return "unloaded" }
        return ([notebook.id] + tickedSources.map(\.id)).joined(separator: "|")
    }

    var body: some View {
        Group {
            if let chat = session.chat {
                MobileNotebookConversation(
                    notebook: notebook,
                    chat: chat,
                    session: session,
                    selection: selection,
                    hidesTabBar: $hidesTabBar,
                    onShowSources: { showsChatSources = true },
                    onAddSources: onAddSources,
                    onTalk: talk
                )
            } else {
                VStack(spacing: 0) {
                    if session.openingChatID != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Opening chat")
                    } else {
                        guide
                    }
                    MobileNotebookComposer(
                        text: $session.draft,
                        placeholder: placeholder,
                        sourceCount: tickedSources.count,
                        notice: composerNotice,
                        isBusy: isPreparing,
                        canSend: canStart,
                        modelName: (session.nextChatModel ?? session.defaultModel)?.name,
                        modelChoices: session.modelChoices,
                        selectedModelID: session.nextChatModel?.id ?? session.defaultModel?.id,
                        onPickModel: { session.nextChatModel = $0 },
                        canTalk: !tickedSources.isEmpty && selection.isLoaded && !live.isActive,
                        hidesTabBar: $hidesTabBar,
                        onShowSources: { showsChatSources = true },
                        onAddSources: onAddSources,
                        onSend: { session.startChat() },
                        onDictated: { text in
                            session.draft = Self.appending(text, to: session.draft)
                            session.startChat()
                        },
                        onTalk: talk
                    )
                }
            }
        }
        .toolbar {
            // Only while the Chat tab is on screen: the notebook's chats,
            // the Mac's Chats menu (`compactChatsMenu`), and, while a chat
            // is open, ChatGPT's compose button, which goes back to the
            // guide and its empty composer (the conversation's "‹ Chats"
            // until 2026-10-06).
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsChatHistory = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .disabled(vm.notebookChats(in: notebook.id).isEmpty)
                .accessibilityLabel("Chats in this notebook")
                .accessibilityIdentifier("notebook.chat.history")
                if session.chat != nil || session.openingChatID != nil {
                    Button {
                        session.closeChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("notebook.chat.new")
                }
            }
        }
        .sheet(isPresented: $showsChatHistory) {
            MobileNotebookChatHistorySheet(notebook: notebook, openChat: openChat)
        }
        .sheet(isPresented: $showsChatSources) {
            MobileNotebookChatSourcesSheet(notebook: notebook, selection: selection)
        }
        .task(id: groundingKey) {
            guard selection.isLoaded else { return }
            session.prepare(notebook: notebook, ticked: tickedSources)
        }
        .task(id: session.chat == nil) {
            await session.loadModelsIfNeeded()
            // A chat saved elsewhere (the Reader's Ask, the Mac) or the one
            // just closed here shows in the guide once the catalog has it.
            // A zone delta behind the snapshot, as opening Sources does.
            if session.chat == nil {
                _ = await vm.load(forceRefresh: true)
            }
        }
    }

    private var isPreparing: Bool {
        if case .preparing = session.grounding { return true }
        return false
    }

    private var canStart: Bool {
        selection.isLoaded && session.readyContext?.loaded.isEmpty == false
    }

    /// The Mac's "Ask about <notebook>…", or, with no source ticked, why
    /// nothing can be asked. How many sources a chat reads is "+"'s.
    private var placeholder: String {
        if selection.isLoaded, tickedSources.isEmpty { return "Tick a source to ask about it" }
        return MobileNotebookComposer.placeholder(for: notebook)
    }

    private var composerNotice: String? {
        if let readError = selection.readError, !selection.isLoaded {
            return "Which sources are in chat could not be read: \(readError)"
        }
        if let openError = session.openError { return openError }
        if let saveError = session.saveError { return saveError }
        if let plan = session.plan {
            if plan.loaded.isEmpty, plan.tickedCount > 0 {
                return plan.doesNotFitCount > 0
                    ? "None of the ticked sources fits whole in a chat; untick some, or ask in the Reader."
                    : MobileNotebookChatGrounding.composerNotice(plan)
            }
            return MobileNotebookChatGrounding.composerNotice(plan)
        }
        return nil
    }

    /// The notebook's guide over its latest chats. No model is called to
    /// draw it.
    private var guide: some View {
        let chats = vm.notebookChats(in: notebook.id)
        let overview = vm.audioOverviews(inNotebook: notebook.id).first
        return ScrollView {
            MobileNotebookGuide(
                notebook: notebook,
                // What its chats draw on, as the Mac's guide counts it: its
                // own sources and the context notebooks put in; sources still
                // on their way to the phone are sources, not an empty notebook.
                hasSources: !MobileNotebookChatSelection.chatPool(
                    of: notebook,
                    selection: selection.current ?? NotebookChatContext.Selection()
                ).isEmpty,
                canAsk: canStart,
                canReview: selection.isLoaded && !tickedSources.isEmpty && !live.isActive,
                overview: overview.map { overview in
                    MobileNotebookGuide.Overview(
                        isPlaying: vm.currentItem?.id == overview.carrier.id && vm.isPlaying,
                        isPreparing: vm.isPreparingAudio(sourceID: overview.carrier.id)
                    )
                },
                recentChats: MobileNotebookChatGuide.recentChats(chats),
                hasMoreChats: MobileNotebookChatGuide.hasMoreChats(chats),
                verdict: vm.continuation(of:),
                onAddSources: onAddSources,
                onSuggestQuestions: suggestQuestions,
                onReview: { MobileNotebookReviewMe.start(notebook: notebook, selection: selection) },
                onListen: {
                    guard let overview else { return }
                    Task { await vm.toggleTextToSpeech(sourceID: overview.carrier.id) }
                },
                onContinueChat: openChat,
                onShowAllChats: { showsChatHistory = true }
            )
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.vertical, MobileDesign.Spacing.xxLarge)
            .mobileReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await vm.load() }
    }

    /// The guide's Suggest questions: the Mac's request, sent as the
    /// learner's message in a new chat on the ticked sources.
    private func suggestQuestions() {
        session.draft = MobileNotebookChatGuide.suggestQuestionsPrompt
        session.startChat()
    }

    /// Opens a saved chat of the notebook to continue it, in this tab
    /// (`MobileNotebookChatSession.continueChat`). Only a chat the phone
    /// continues reaches here; the others open read-only in the stack.
    private func openChat(_ summary: MobileNotebookChatSummary) {
        let found = MobileNotebookChatContinuation.sources(of: summary.sourceIDs) { vm.sourcesByID[$0] }
        session.continueChat(
            summary,
            notebook: notebook,
            sources: found.onPhone,
            missingSourceCount: found.missingCount,
            transcript: { await vm.chatTranscript(sessionID: summary.id) }
        )
    }

    /// A voice conversation on what the chat reads: the chat under way,
    /// continued by voice in the same chat, or a new chat on the ticked
    /// sources, the context notebooks put in included, filed under the
    /// notebook.
    private func talk() {
        if let chat = session.chat, !chat.messages.isEmpty {
            Task { await live.start(continuing: chat, finishesWhenDone: false) }
            return
        }
        let ticked = selection.chatSourceIDs(of: notebook)
        Task { await live.start(notebook: notebook.narrowed(toSourceIDs: ticked)) }
    }

    fileprivate static func appending(_ spoken: String, to draft: String) -> String {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? text : "\(existing) \(text)"
    }
}

/// The empty Chat tab, as the Mac draws a notebook chat's empty state
/// (`NotebookChatGuide`): the notebook's glyph and name in the guide's serif,
/// the description stored on it, and — only when it has sources — Suggest
/// questions and Quiz me on it, with Listen when it has an audio overview;
/// Add sources for an empty one. Under them its latest chats, each a tap from
/// coming back, and All chats when it has more. How many sources a chat
/// reads is the composer's "+" › Choose Sources, not said twice.
private struct MobileNotebookGuide: View {
    /// The notebook's newest audio overview, as Listen plays it.
    struct Overview {
        let isPlaying: Bool
        let isPreparing: Bool
    }

    let notebook: MobileCloudNotebook
    let hasSources: Bool
    /// A chat on the ticked sources can start now.
    let canAsk: Bool
    let canReview: Bool
    let overview: Overview?
    let recentChats: [MobileNotebookChatSummary]
    let hasMoreChats: Bool
    let verdict: (MobileNotebookChatSummary) -> MobileNotebookChatContinuation.Verdict
    let onAddSources: () -> Void
    let onSuggestQuestions: () -> Void
    let onReview: () -> Void
    let onListen: () -> Void
    let onContinueChat: (MobileNotebookChatSummary) -> Void
    let onShowAllChats: () -> Void

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.xLarge) {
            VStack(spacing: MobileDesign.Spacing.small) {
                // A cover with nothing behind it, as the Mac's guide draws it; the emoji on a tint.
                MobileNotebookIconView(notebookID: notebook.id, size: 56, cornerRadius: 14, plate: Color.accentColor.opacity(0.10)) {
                    Text(NotebookTitle(notebook.title).displayIcon)
                        .font(.largeTitle)
                }
                .accessibilityHidden(true)
                .padding(.bottom, MobileDesign.Spacing.xSmall)
                Text(NotebookTitle(notebook.title).text)
                    .font(.system(.title2, design: .serif, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let summary = notebook.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions

            if !recentChats.isEmpty {
                recentChatList
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook.chat.guide")
    }

    /// Suggest questions and Quiz me on it for a notebook with sources, Add
    /// sources for an empty one, and Listen beside either when there is an
    /// overview. Side by side while they fit, else one above another.
    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MobileDesign.Spacing.small) { actionButtons }
            VStack(spacing: MobileDesign.Spacing.small) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if hasSources {
            Button(action: onSuggestQuestions) {
                MobileGuideChip(title: "Suggest questions", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(!canAsk)
            .accessibilityIdentifier("notebook.guide.suggestQuestions")

            Button(action: onReview) {
                MobileGuideChip(title: "Quiz me on it", systemImage: "graduationcap")
            }
            .buttonStyle(.plain)
            .disabled(!canReview)
            .accessibilityIdentifier("notebook.guide.review")
        } else {
            Button(action: onAddSources) {
                Label("Add sources", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("notebook.guide.addSources")
        }
        if let overview {
            Button(action: onListen) {
                MobileGuideChip(
                    title: overview.isPlaying ? "Pause" : "Listen",
                    systemImage: overview.isPlaying ? "pause.fill" : "waveform",
                    isBusy: overview.isPreparing
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(overview.isPlaying ? "Pause audio overview" : "Listen to audio overview")
            .accessibilityIdentifier("notebook.guide.listen")
        }
    }

    /// The latest chats, as the Mac's guide lists them: the chat's glyph,
    /// its title and when it last moved. One the phone continues opens here;
    /// any other opens read-only.
    private var recentChatList: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentChats.enumerated()), id: \.element.id) { index, chat in
                if index > 0 {
                    Divider().padding(.leading, MobileDesign.Spacing.medium + 28 + MobileDesign.Spacing.small)
                }
                if verdict(chat) == .continuable {
                    Button { onContinueChat(chat) } label: { recentChatRow(chat) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open chat \(chat.title)")
                        .accessibilityIdentifier("notebook.guide.recentChat")
                } else {
                    NavigationLink(value: MobileShellRoute.savedChat(sessionID: chat.id, title: chat.title)) {
                        recentChatRow(chat)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chat \(chat.title)")
                    .accessibilityIdentifier("notebook.guide.recentChat")
                }
            }
            if hasMoreChats {
                Divider().padding(.leading, MobileDesign.Spacing.medium + 28 + MobileDesign.Spacing.small)
                Button(action: onShowAllChats) {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        Text("All chats")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: MobileDesign.Spacing.small)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, MobileDesign.Spacing.medium)
                    .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("notebook.guide.allChats")
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats in this notebook")
        .accessibilityIdentifier("notebook.guide.recentChats")
    }

    private func recentChatRow(_ chat: MobileNotebookChatSummary) -> some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: "bubble.left")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(chat.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: MobileDesign.Spacing.small)
            Text(chat.lastActivityAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }
}

/// One of the guide's chips, the Mac's `NotebookChatGuide.chip`: a glyph
/// beside its word in a quiet capsule.
private struct MobileGuideChip: View {
    let title: String
    let systemImage: String
    var isBusy = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
        .background(Color.primary.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
    }
}

/// Every chat of the notebook, newest first, from the Chat tab's toolbar
/// and the guide's All chats, under a search field that narrows them by
/// title as the Mac's All chats does: one the phone continues opens in the
/// Chat tab; any other opens here, read-only.
private struct MobileNotebookChatHistorySheet: View {
    let notebook: MobileCloudNotebook
    let openChat: (MobileNotebookChatSummary) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let chats = MobileNotebookChatGuide.chats(vm.notebookChats(in: notebook.id), matching: query)
        NavigationStack {
            List {
                ForEach(chats) { chat in
                    if vm.continuation(of: chat) == .continuable {
                        Button {
                            dismiss()
                            openChat(chat)
                        } label: {
                            MobileNotebookChatRow(summary: chat)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notebook.chat.row")
                    } else {
                        NavigationLink {
                            MobileNotebookSavedChatScreen(sessionID: chat.id, title: chat.title)
                        } label: {
                            MobileNotebookChatRow(summary: chat)
                        }
                        .accessibilityIdentifier("notebook.chat.row")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if chats.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The composer's "+" › Choose Sources: what a new chat reads — the Sources tab's
/// boxes (the member's two rows, through the same store), with Select all and
/// "9 of 13 in chat", in the chats' order: the notebook's own sources, then
/// each context notebook as its group with its box. Linking and unlinking
/// stay in Sources.
private struct MobileNotebookChatSourcesSheet: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var selection: MobileNotebookChatSelectionStore

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    /// The context notebooks whose sources are shown.
    @State private var openGroups = Set<String>()

    private var sources: [MobileCloudSource] {
        vm.notebookSources(in: notebook)
    }

    var body: some View {
        let board = selection.board(for: notebook)
        let groups = vm.contextNotebookGroups(in: notebook)
        let tally = MobileNotebookChatTally(board: board, own: sources, groups: groups)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        Text(tally.ofLine(own: sources.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if tally.hasRows(own: sources.count) {
                            Text("Select all")
                                .font(.subheadline)
                            MobileChatTickBox(
                                state: tally.state,
                                label: "Select all for chat",
                                isEnabled: tally.isLoaded,
                                action: { toggleAll(tally) }
                            )
                            .accessibilityIdentifier("notebook.chatSources.selectAll")
                        }
                    }
                    if let message = selection.readError ?? selection.writeError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                if !sources.isEmpty {
                    Section {
                        ForEach(sources) { source in
                            row(source, board: board, through: nil)
                        }
                    }
                }
                ForEach(groups) { group in
                    let isOpen = openGroups.contains(group.id)
                    let state = board?.state(ofContextNotebook: group.id, shown: group.sources.map(\.id)) ?? .unchecked
                    Section {
                        MobileContextNotebookHeader(
                            group: group,
                            state: state,
                            isEnabled: board != nil,
                            isExpanded: isOpen,
                            onToggleExpanded: {
                                if isOpen { openGroups.remove(group.id) } else { openGroups.insert(group.id) }
                            },
                            onTick: {
                                Task { await selection.setContextNotebooks([group.id], inChat: state != .checked, in: notebook) }
                            }
                        )
                        if isOpen {
                            ForEach(group.sources) { source in
                                row(source, board: board, through: group.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// A source's row; `group` names the context notebook whose group it is
    /// in, nil for the notebook's own.
    private func row(_ source: MobileCloudSource, board: MobileNotebookChatBoard?, through group: String?) -> some View {
        let isInChat = board?.isInChat(source.id) ?? false
        return HStack(spacing: MobileDesign.Spacing.medium) {
            MobileSourceIconTile(sourceType: source.sourceType, size: CGSize(width: 36, height: 36))
                .accessibilityHidden(true)
            Text(source.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            MobileChatTickBox(
                state: isInChat ? .checked : .unchecked,
                label: "Include \(source.title) in chat",
                isEnabled: board != nil,
                action: { toggle(source, isInChat: isInChat, through: group) }
            )
            .accessibilityIdentifier("notebook.chatSources.tick")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard board != nil else { return }
            toggle(source, isInChat: isInChat, through: group)
        }
    }

    private func toggle(_ source: MobileCloudSource, isInChat: Bool, through group: String?) {
        Task { await selection.set([source.id], inChat: !isInChat, through: group, in: notebook) }
    }

    /// Select all: every box ticked clears them all, anything else ticks all
    /// (the Mac's Select all, as the Sources tab's).
    private func toggleAll(_ tally: MobileNotebookChatTally) {
        guard tally.isLoaded else { return }
        let inChat = tally.state != .checked
        Task { await selection.setAll(inChat: inChat, in: notebook) }
    }
}

/// The chat under way, with its own composer bound to it. No bar of its own
/// over the transcript (2026-10-06): New Chat and the notebook's chats are
/// the toolbar's, and Copy Conversation and Read Replies Aloud each finished
/// reply's ⋯.
private struct MobileNotebookConversation: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var chat: MobileChatViewModel
    @ObservedObject var session: MobileNotebookChatSession
    @ObservedObject var selection: MobileNotebookChatSelectionStore
    @Binding var hidesTabBar: Bool
    let onShowSources: () -> Void
    let onAddSources: () -> Void
    let onTalk: () -> Void

    @ObservedObject private var live = MobileVoiceConversationController.shared

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if chat.signInState == .signedOut {
                MobileSignInPrompt {
                    Task {
                        await chat.refreshSignInState()
                        chat.sendInitialPromptIfNeeded()
                    }
                }
                .padding(MobileDesign.Spacing.medium)
            } else {
                MobileNotebookComposer(
                    text: $chat.draft,
                    placeholder: placeholder,
                    sourceCount: chat.notebookContext?.loaded.count ?? 0,
                    notice: notice,
                    isBusy: false,
                    canSend: chat.canSend,
                    modelName: (chat.modelOverride ?? session.defaultModel)?.name,
                    modelChoices: session.modelChoices,
                    selectedModelID: chat.modelOverride?.id ?? session.defaultModel?.id,
                    onPickModel: { chat.modelOverride = $0 },
                    canTalk: chat.notebookContext?.loaded.isEmpty == false && !live.isActive && !chat.isResponding,
                    hidesTabBar: $hidesTabBar,
                    onShowSources: onShowSources,
                    onAddSources: onAddSources,
                    onSend: { chat.send() },
                    onDictated: { text in
                        chat.appendDictatedText(text)
                        chat.send()
                    },
                    onTalk: onTalk
                )
            }
        }
        .task {
            await chat.refreshSignInState()
            chat.sendInitialPromptIfNeeded()
        }
    }

    /// The chat reads the sources it began with (as on the Mac) — a
    /// continued one, the sources the saved chat read; the ticks govern the
    /// next chat. One none of whose sources loaded says it cannot be asked.
    private var placeholder: String {
        if chat.notebookContext?.loaded.isEmpty != false { return "No source to read yet" }
        return MobileNotebookComposer.placeholder(for: notebook)
    }

    private var notice: String? {
        if let error = chat.errorMessage { return AIProviderErrorText.clamped(error) }
        if let saveError = session.saveError { return saveError }
        guard let notebookContext = chat.notebookContext else { return nil }
        let plan = MobileNotebookChatGrounding.Plan(
            loaded: notebookContext.loaded.map(\.source.id),
            notLoaded: notebookContext.notLoaded.map { .init(sourceID: $0.source.id, reason: $0.reason) }
        )
        if let continuation = chat.continuation {
            return MobileNotebookChatContinuation.notice(plan, missingCount: continuation.missingSourceCount)
        }
        guard !notebookContext.notLoaded.isEmpty else { return nil }
        return MobileNotebookChatGrounding.composerNotice(plan)
    }

    private var copiedText: String {
        ConversationTranscriptFormatter.plainText(
            from: chat.messages.map {
                ConversationTranscriptFormatter.Turn(
                    speaker: $0.role == .user ? .user : .assistant,
                    content: $0.content
                )
            }
        )
    }

    /// What each finished reply's footer does.
    private var replyActions: MobileChatReplyActions {
        MobileChatReplyActions(chat: chat, conversationText: { copiedText })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        MobileChatBubble(message: message, replyActions: replyActions)
                            .equatable()
                            .id(message.id)
                    }
                    ForEach(chat.queuedMessages) { queued in
                        MobileQueuedChatBubble(message: queued) {
                            chat.returnQueuedMessageToDraft(queued.id)
                        }
                        .id(queued.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.large)
                .mobileReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) { _, _ in
                guard let id = chat.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.content) { _, _ in
                guard let id = chat.messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            // A finished reply grows its footer: keep it in view.
            .onChange(of: chat.messages.last?.isStreaming) { _, _ in
                guard let id = chat.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

/// The notebook chat's composer, ChatGPT's and the Mac's one rounded box
/// (2026-10-06): the field on top, saying "Ask about <notebook>…"; under it
/// "+" on the leading edge (Choose Sources, with how many the chat reads, and
/// Add Sources), and on the trailing edge the model chip, dictation, and one
/// round button — Talk while the field is empty, a filled ↑ once it is not.
/// Over the box, a line only when something is wrong: not every ticked source
/// is read, a reply or a save failed, dictation could not start.
private struct MobileNotebookComposer: View {
    @Binding var text: String
    let placeholder: String
    /// The ticked sources a new chat reads, or the ones the chat under way
    /// reads.
    let sourceCount: Int
    let notice: String?
    let isBusy: Bool
    let canSend: Bool
    let modelName: String?
    let modelChoices: [MobileChatModelChoice]
    let selectedModelID: String?
    let onPickModel: (MobileChatModelChoice) -> Void
    let canTalk: Bool
    @Binding var hidesTabBar: Bool
    let onShowSources: () -> Void
    let onAddSources: () -> Void
    let onSend: () -> Void
    let onDictated: (String) -> Void
    let onTalk: () -> Void

    @StateObject private var dictation = MobileComposerDictation()
    @FocusState private var isFocused: Bool

    private var isListening: Bool { dictation.state == .listening }

    /// The Mac's notebook placeholder (`chatInputPlaceholder`), the name
    /// without its emoji.
    static func placeholder(for notebook: MobileCloudNotebook) -> String {
        "Ask about \(NotebookTitle(notebook.title).text)…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            if let notice, !notice.isEmpty {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notebook.chat.notice")
            }
            if let dictationError {
                Text(dictationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            MobileComposerSurface {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(placeholder, text: fieldText, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .disabled(isListening)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, MobileDesign.Spacing.xSmall)
                        .padding(.top, MobileDesign.Spacing.small)
                        .accessibilityIdentifier("notebook.chat.composer")
                    controls
                }
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, MobileDesign.Spacing.small)
        .mobileReadableWidth()
        .background(.ultraThinMaterial)
        .task { await dictation.refreshAvailability() }
        .onDisappear { Task { await dictation.cancel() } }
        // The keyboard needs the room the tab bar takes.
        .onChange(of: isFocused) { _, focused in hidesTabBar = focused }
    }

    /// The row under the field: "+", then the model, the mic and the round
    /// button. Each glyph sits in a 44-point target; the row reaches into the
    /// box's padding so the outer glyphs line up with the field's words.
    private var controls: some View {
        HStack(spacing: 0) {
            addMenu
            Spacer(minLength: MobileDesign.Spacing.small)
            modelMenu
            if dictation.isAvailable {
                Button {
                    dictation.toggle { spoken in onDictated(spoken) }
                } label: {
                    Image(systemName: isListening ? "stop.fill" : "mic")
                        .font(.body.weight(.medium))
                        .foregroundStyle(isListening ? Color.red : Color.secondary)
                        .frame(
                            width: MobileDesign.Metrics.minimumTouchTarget,
                            height: MobileDesign.Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop dictation" : "Dictate a question")
                .accessibilityIdentifier("notebook.chat.dictate")
            }
            roundButton
        }
        .padding(.horizontal, -MobileDesign.Spacing.small)
    }

    /// "+", ChatGPT's and the Mac's: what the chat reads, and a way to add
    /// to the notebook. Until 2026-10-06 the count was a "9 sources" chip
    /// over the field.
    private var addMenu: some View {
        Menu {
            Button(action: onShowSources) {
                Label {
                    Text("Choose Sources…")
                    Text("\(sourceCount) in chat")
                } icon: {
                    Image(systemName: "books.vertical")
                }
            }
            .accessibilityIdentifier("notebook.chat.sources")
            Button(action: onAddSources) {
                Label("Add Sources…", systemImage: "plus")
            }
            .accessibilityIdentifier("notebook.chat.addSources")
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: MobileDesign.Metrics.minimumTouchTarget,
                    height: MobileDesign.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sources")
        .accessibilityValue(sourceCount == 1 ? "1 source in chat" : "\(sourceCount) sources in chat")
        .accessibilityIdentifier("notebook.chat.add")
    }

    /// The chat's model, its name and a chevron, as the Mac's chip reads
    /// with no glyph. The phone sets no effort, so none is named.
    private var modelMenu: some View {
        Menu {
            if modelChoices.isEmpty {
                Text("The models you offer in ForeverLM on your Mac appear here.")
            }
            ForEach(modelChoices) { choice in
                Button {
                    onPickModel(choice)
                } label: {
                    if choice.id == selectedModelID {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(modelName ?? "Model")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MobileDesign.Spacing.xSmall)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Model: \(modelName ?? "default")")
        .accessibilityIdentifier("notebook.chat.model")
    }

    /// Talk while there is nothing to send, send once there is (a spinner
    /// while the sources a new chat reads are still being read).
    @ViewBuilder
    private var roundButton: some View {
        if !hasSomethingToSend {
            Button(action: onTalk) {
                MobileComposerDiscLabel(systemImage: "waveform")
            }
            .buttonStyle(.plain)
            .disabled(!canTalk)
            .accessibilityLabel("Talk about this Notebook")
            .accessibilityIdentifier("notebook.chat.talk")
        } else if isBusy, !isListening {
            ProgressView()
                .controlSize(.small)
                .frame(
                    width: MobileDesign.Metrics.minimumTouchTarget,
                    height: MobileDesign.Metrics.minimumTouchTarget
                )
                .accessibilityLabel("Reading the sources")
        } else {
            Button(action: send) {
                MobileComposerDiscLabel(systemImage: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!canSendNow)
            .accessibilityLabel(isListening ? "Transcribe and send" : "Send")
            .accessibilityIdentifier("notebook.chat.send")
        }
    }

    /// Typed words, or dictation under way.
    private var hasSomethingToSend: Bool {
        isListening || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fieldText: Binding<String> {
        Binding(
            get: { isListening ? dictation.partialText : text },
            set: { newValue in
                guard !isListening else { return }
                text = newValue
            }
        )
    }

    private var canSendNow: Bool {
        if isListening {
            return !dictation.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        isFocused = false
        guard isListening else {
            guard canSendNow else { return }
            onSend()
            return
        }
        Task {
            // The final transcript reaches the toggle's handler, which sends.
            await dictation.finish()
        }
    }

    private var dictationError: String? {
        switch dictation.state {
        case .denied(let message), .failed(let message): return message
        case .idle, .requestingPermission, .listening: return nil
        }
    }
}

/// One saved chat in a notebook's list: its kind's grey glyph, its title, and
/// when it last moved ("2 hr. ago"). The accent glyph and the turn count went
/// on 2026-10-06, ChatGPT's list has neither.
struct MobileNotebookChatRow: View {
    let summary: MobileNotebookChatSummary

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch summary.kind {
        case .text: return "text.bubble"
        case .voice: return "waveform"
        case .memory: return MemoryReviewSession.sidebarIcon
        }
    }

    private var subtitle: String {
        summary.lastActivityAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// A saved chat the phone does not continue, read-only, in the notebook's
/// stack: a memory review, a review or quiz, a walk's chat, or one whose
/// sources are not here (`MobileNotebookChatContinuation.verdict`). One
/// plain line at its foot says why; a chat the phone continues opens in
/// the notebook's Chat tab instead.
struct MobileNotebookSavedChatScreen: View {
    let sessionID: String
    let title: String

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var transcript: MobileVoiceChatTranscript?
    @State private var isMissing = false

    /// Why this chat is read here and not continued; nil when nothing says.
    private var readOnlyReason: String? {
        guard let chat = vm.notebookChat(sessionID: sessionID),
              case .readOnly(let reason) = vm.continuation(of: chat) else { return nil }
        return reason
    }

    var body: some View {
        Group {
            if let transcript {
                MobileVoiceTranscriptView(transcript: transcript)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let readOnlyReason {
                            Text(readOnlyReason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(MobileDesign.Spacing.medium)
                                .background(.bar)
                                .accessibilityIdentifier("notebook.savedChat.readOnly")
                        }
                    }
            } else if isMissing {
                ContentUnavailableView(
                    "Chat Not Here",
                    systemImage: "text.bubble",
                    description: Text("This chat is no longer on this iPhone.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            transcript = await vm.chatTranscript(sessionID: sessionID)
            isMissing = transcript == nil
        }
    }
}
