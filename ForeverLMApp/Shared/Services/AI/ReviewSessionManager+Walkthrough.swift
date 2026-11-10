// Part of ReviewSessionManager: walkthrough playback and the reader focus tools.

import Foundation

extension ReviewSessionManager {
    // MARK: - Walkthrough playback

    /// The walkthrough this chat is playing: one pre-written, validated record
    /// a source carries, shown one assistant turn a step with no model call
    /// (walkthrough-design.md, "the panel becomes a chat"). Set when Walk
    /// Through opens or joins this chat, and restored when a chat whose turns
    /// carry `WalkthroughStepTurn` lines is reopened. A model is called only
    /// when the learner types.
    struct WalkthroughPlayback: Equatable {
        /// What the walk is of: a source read in the Reader, or a saved
        /// animation shown in the Animations pane (product owner, 2026-09-20).
        enum Subject: Equatable {
            case source(StudioArticle)
            case animation(ArtifactRecord)

            var id: String {
                switch self {
                case .source(let article): return article.id
                case .animation(let artifact): return artifact.id
                }
            }

            var title: String {
                switch self {
                case .source(let article): return article.title
                case .animation(let artifact): return artifact.title
                }
            }

            var article: StudioArticle? {
                if case .source(let article) = self { return article }
                return nil
            }

            var animation: ArtifactRecord? {
                if case .animation(let artifact) = self { return artifact }
                return nil
            }
        }

        let subject: Subject
        var walkthrough: PaperWalkthrough
        var figures: [PaperFigureRecord]
        var pdfPath: String?
        /// The saved animations the steps refer to, by id, for their pages.
        var animations: [String: ArtifactRecord] = [:]
        /// Record index of the step the learner is on: the newest one played,
        /// or an earlier one Back went to.
        var currentIndex: Int
        /// Steps already in the transcript.
        var playedStepIDs: Set<String>
        /// Question steps the learner has sent an answer to; the grading brief
        /// rides beside that one message and no other.
        var answeredQuizStepIDs: Set<String> = []
        /// How many of a step's beats the chat shows, by step id. A step is
        /// played at its first beat and Next reveals the rest one at a time
        /// (walkthrough-design.md, "one sentence a click"); a step played
        /// before the chat was reopened has no entry and shows them all.
        var revealedBeats: [String: Int] = [:]
        /// Where each question card stands, by step id: answer shown, then
        /// graded by the learner (product owner, 2026-09-22, after quantum.country:
        /// "reading and quizzing within one interface").
        var recall: [String: WalkthroughRecall] = [:]
        /// The chat the learner's questions about this walk go to. Nil until
        /// the first is asked: the walk is not a chat, and dealing its cards
        /// makes none (walkthrough-design.md, "the walk leaves the chat").
        var chatSessionID: String?

        /// What `walkthrough_progress` keeps of this playback.
        var progress: WalkthroughProgress {
            var outcomes: [String: WalkthroughProgress.Outcome] = [:]
            for (stepID, state) in recall {
                switch state {
                case .remembered: outcomes[stepID] = .remembered
                case .forgot: outcomes[stepID] = .forgot
                case .answered: outcomes[stepID] = .answered
                case .revealed: break
                }
            }
            return WalkthroughProgress(
                subjectID: sourceID,
                currentStepID: currentStep?.id,
                revealedBeats: revealedBeats,
                playedStepIDs: steps.map(\.id).filter { playedStepIDs.contains($0) },
                outcomes: outcomes,
                chatSessionID: chatSessionID
            )
        }

        /// Takes up where `progress` left the walk. Step ids the record no
        /// longer has (a walk written again) are dropped.
        mutating func adopt(_ progress: WalkthroughProgress) {
            let ids = Set(steps.map(\.id))
            if let current = progress.currentStepID, let index = steps.firstIndex(where: { $0.id == current }) {
                currentIndex = index
            }
            playedStepIDs = Set(progress.playedStepIDs.filter(ids.contains))
            revealedBeats = progress.revealedBeats.filter { ids.contains($0.key) }
            recall = [:]
            answeredQuizStepIDs = []
            for (stepID, outcome) in progress.outcomes where ids.contains(stepID) {
                switch outcome {
                case .remembered: recall[stepID] = .remembered
                case .forgot: recall[stepID] = .forgot
                case .answered: recall[stepID] = .answered
                }
                answeredQuizStepIDs.insert(stepID)
            }
            chatSessionID = progress.chatSessionID
        }

        init(
            subject: Subject,
            walkthrough: PaperWalkthrough,
            figures: [PaperFigureRecord] = [],
            pdfPath: String? = nil,
            animations: [String: ArtifactRecord] = [:],
            currentIndex: Int,
            playedStepIDs: Set<String>
        ) {
            self.subject = subject
            self.walkthrough = walkthrough
            self.figures = figures
            self.pdfPath = pdfPath
            self.animations = animations
            self.currentIndex = currentIndex
            self.playedStepIDs = playedStepIDs
        }

        init(
            article: StudioArticle,
            walkthrough: PaperWalkthrough,
            figures: [PaperFigureRecord],
            pdfPath: String?,
            currentIndex: Int,
            playedStepIDs: Set<String>
        ) {
            self.init(subject: .source(article), walkthrough: walkthrough, figures: figures, pdfPath: pdfPath, currentIndex: currentIndex, playedStepIDs: playedStepIDs)
        }

        /// The source, for a source walk; nil for an animation walk.
        var article: StudioArticle? { subject.article }
        /// The subject's id — a source id or an artifact id — which the step
        /// markers and the storage key the walk by.
        var sourceID: String { subject.id }
        /// The library sources the walk is about: its own source, or the
        /// sources an animation was drawn from.
        var aboutSourceIDs: Set<String> {
            switch subject {
            case .source(let article): [article.id]
            case .animation(let artifact): Set(artifact.sourceIDs)
            }
        }
        var isAnimationWalk: Bool { subject.animation != nil }
        var steps: [PaperWalkthroughStep] { walkthrough.steps }

        /// The record of the animation a step refers to, when the library has it.
        func animationRecord(for step: PaperWalkthroughStep) -> ArtifactRecord? {
            guard let reference = step.animation else { return nil }
            if let record = animations[reference.animationID] { return record }
            if let own = subject.animation, own.id == reference.animationID { return own }
            return nil
        }

        /// The page the step's card loads: the animation's address with the
        /// step's walk parameters. Nil when the step shows no saved animation
        /// or the animation is gone.
        func animationPageURL(for step: PaperWalkthroughStep) -> URL? {
            guard let reference = step.animation,
                  let record = animationRecord(for: step),
                  let linked = record.linkedURL, let url = URL(string: linked) else { return nil }
            return reference.pageURL(animationURL: url)
        }
        var currentStep: PaperWalkthroughStep? {
            steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
        }
        /// Back has somewhere to go: an earlier beat of this step, or an
        /// earlier step.
        var canGoBack: Bool {
            currentIndex > 0 || (currentStep.map { revealedBeatCount(of: $0) > 1 } ?? false)
        }
        /// Next has somewhere to go: a beat of this step not shown yet, or a
        /// later step.
        var canGoNext: Bool { currentIndex + 1 < steps.count || currentStepHasBeatsLeft }

        /// A step's cards, never fewer than one: a step with no words still
        /// takes one press to show. The walk's, not the step's, so a
        /// chapter's recap card is counted (`PaperWalkthrough.playableBeats(of:)`).
        func beatCount(of step: PaperWalkthroughStep) -> Int {
            max(1, walkthrough.playableBeats(of: step).count)
        }

        /// The card the learner is on within the step: its beat, or nil for
        /// a step with no words.
        func currentBeat(of step: PaperWalkthroughStep) -> WalkthroughBeat? {
            let beats = walkthrough.playableBeats(of: step)
            let index = revealedBeatCount(of: step) - 1
            return beats.indices.contains(index) ? beats[index] : nil
        }

        func revealedBeatCount(of step: PaperWalkthroughStep) -> Int {
            let count = beatCount(of: step)
            return min(count, max(1, revealedBeats[step.id] ?? count))
        }

        /// Whether Next, on the current step, shows another of its beats
        /// rather than moving on.
        var currentStepHasBeatsLeft: Bool {
            guard let step = currentStep, playedStepIDs.contains(step.id) else { return false }
            return revealedBeatCount(of: step) < beatCount(of: step)
        }

        func step(id: String) -> PaperWalkthroughStep? {
            steps.first { $0.id == id }
        }

        func marker(at index: Int) -> WalkthroughStepTurn.Marker? {
            guard steps.indices.contains(index) else { return nil }
            return WalkthroughStepTurn.Marker(sourceID: sourceID, stepID: steps[index].id, index: index, count: steps.count)
        }

        /// The figure record a step's anchor names, from the source's index.
        /// The row the chip reads its title and panel caption from: the
        /// figure's own row, with its words taken from the continuation row
        /// when the figure's page only says "See next page for caption".
        func figureRecord(for step: PaperWalkthroughStep) -> PaperFigureRecord? {
            guard let label = step.anchor?.figureLabel, !label.isEmpty else { return nil }
            return figureRecord(labelled: label)
        }

        /// The figure record a label names, read as `figureRecord(for:)` reads
        /// a step's: what a card's picture takes its caption from.
        func figureRecord(labelled label: String) -> PaperFigureRecord? {
            guard let record = WalkthroughAnchorResolver.figureRecord(labelled: label, in: figures) else { return nil }
            return PaperWalkthroughGeneratorService.displayRecord(for: record, in: figures)
        }
    }

    /// A question card, mnemonic-medium style: the learner answers in their
    /// head, shows the answer, and says whether they had it — or types an
    /// answer, which the tutor grades, or picks a panel on a Find it.
    enum WalkthroughRecall: Equatable {
        /// Show answer was pressed; Forgot or Remembered comes next.
        case revealed
        /// An answer was typed into the chat: the tutor's reply is the grade,
        /// the reference answer shows, and no self-grade is asked for. A
        /// prediction's veil lifts here.
        case answered
        case remembered
        case forgot
    }

    /// Every change to where the learner is, or how a question went, is
    /// saved to the walk's own record (`walkthrough_progress`), wherever it
    /// came from: a card dealt, Back, a jump, a grade. Keyed on the progress
    /// value, not on which call moved it, so no move path can forget to save.
    func persistWalkthroughProgressIfChanged() {
        guard let playback = walkthroughPlayback, !playback.playedStepIDs.isEmpty else { return }
        var progress = playback.progress
        if var last = persistedWalkthroughProgress, last.subjectID == progress.subjectID {
            last.updatedAt = progress.updatedAt
            if last == progress { return }
        }
        progress.updatedAt = Date()
        persistedWalkthroughProgress = progress
        let previous = walkthroughProgressSave
        let storage = storage
        let logger = logger
        walkthroughProgressSave = Task {
            await previous?.value
            do {
                try await storage.saveWalkthroughProgress(progress)
            } catch {
                logger.error("Failed to save walkthrough progress for \(progress.subjectID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for the progress saves already queued; tests read the record
    /// after it.
    func flushWalkthroughProgressSaves() async {
        await walkthroughProgressSave?.value
    }
    /// The step row the transcript should bring to the top of the chat: set
    /// on every move in the walk — a step played, Back, Next, a jump from the
    /// strip — so the row under the strip and the outline on the page are the
    /// same step (product owner, 2026-09-21: "Going front and back here in a
    /// walkthrough should be more smooth"). The transcript otherwise scrolls
    /// only when the learner sends a message, so a played step landed below
    /// the fold and Back changed the page with no sign of it in the chat. The
    /// token makes a repeat of the same step a fresh request. A chip pressed
    /// on an older row points the page and asks for no scroll.
    struct WalkthroughStepScrollRequest: Equatable {
        let stepID: String
        let token: UUID
    }
    private func requestWalkthroughStepScroll(to stepID: String) {
        walkthroughStepScrollRequest = WalkthroughStepScrollRequest(stepID: stepID, token: UUID())
    }
    /// What the chat's window and the other windows have open, less what the
    /// learner left out of this chat. Nil for a chat outside a Studio window.
    func openPanesForThisChat() -> ChatOpenPanes? {
        openPanesProvider.map { provider in
            var panes = provider()
            panes.pinnedCard = pinnedCard
            return panes.leavingOut(onScreenSourcesLeftOut)
        }
    }

    /// The chip's ×: this chat stops seeing the source while it stays open.
    func leaveOutOnScreenSource(_ sourceID: String) {
        onScreenSourcesLeftOut.insert(sourceID)
    }

    /// Forgets the left-out sources no longer on screen in the chat's window,
    /// so the × lasts as long as the learner keeps that source open.
    func keepOnScreenSourcesLeftOut(within onScreenIDs: Set<String>) {
        let kept = onScreenSourcesLeftOut.intersection(onScreenIDs)
        if kept != onScreenSourcesLeftOut { onScreenSourcesLeftOut = kept }
    }

    /// True when a Reader beside this chat has `sourceID` on screen, so the
    /// outline on its page is the picture and the row needs no lens.
    private func readerBesideChatShows(_ sourceID: String) -> Bool {
        walkthroughReaderShowsSource?(sourceID) ?? false
    }

    /// Whether a Reader beside this chat shows `article`, as pages or as
    /// text — opening it there first when none does. A passage of an article
    /// is flashed by the Reader showing it, so pointing at one with no Reader
    /// open showed nothing at all.
    func readerBesideChatShowsOpening(_ article: StudioArticle) async -> Bool {
        guard walkthroughFocusHandler != nil else { return false }
        if readerBesideChatShows(article.id) { return true }
        // A tutor going through a figure panel by panel calls again before
        // the Reader it just opened has mounted; opening it a second time
        // would reload the page under the outline.
        if let opened = sourceOpenedBesideChat, opened.id == article.id,
           Date().timeIntervalSince(opened.at) < 5 {
            return true
        }
        guard let readerBesideChatOpener, await readerBesideChatOpener(article.id) else { return false }
        sourceOpenedBesideChat = (article.id, Date())
        return true
    }
    /// Whether this chat is playing `sourceID`'s walkthrough.
    func isPlayingWalkthrough(of sourceID: String) -> Bool {
        walkthroughPlayback?.sourceID == sourceID
    }

    /// Loads the source's record, figure index and PDF path for playing. The
    /// resolver's caches survive a reload of the same index and file (an
    /// animation arriving redraws the same walk); a changed index or file
    /// starts them over. False when the source has no usable walkthrough, or
    /// when this chat is a conversation the walk is no part of
    /// (`chatTakesWalkthrough`).
    @discardableResult
    func loadWalkthrough(for article: StudioArticle) async -> Bool {
        await whileOpeningWalkthrough(article.id) {
            guard var loaded = try? await storage.loadPaperWalkthrough(article.id), loaded.isUsable else {
                if walkthroughPlayback?.sourceID == article.id { clearWalkthroughPlayback() }
                return false
            }
            // A record written before figure steps kept the authors' sentence
            // about their panel (2026-09-21) is given it here, from the text
            // the record was written against; nothing is saved back.
            if loaded.needsSourceMentions, let text = await storage.loadSourceContent(article.id), !text.isEmpty {
                loaded = loaded.fillingSourceMentions(from: text)
            }
            var records = (try? await storage.paperFigures(sourceID: article.id)) ?? []
            var target = try? await storage.paperFigureIndexTarget(sourceID: article.id)
            // An index read by an older build is read again before the walk
            // shows it: the walk otherwise keeps that build's pages, like
            // Figure 1 of the EMBO cristae paper on its legend's page of prose
            // (2026-09-28). Structure only — no model, nothing spent.
            if let stale = target, stale.targetVersion < PaperFigureIndexContract.currentVersion,
               let fresh = try? await paperFigureIndexer.prepareStructure(sourceID: article.id), !fresh.isEmpty {
                records = fresh
                target = try? await storage.paperFigureIndexTarget(sourceID: article.id)
            }
            return await installWalkthroughPlayback(
                subject: .source(article),
                loaded: loaded,
                figures: records,
                pdfPath: target?.pdfPath
            )
        }
    }

    /// The animation walk: the record the animation carries, with the
    /// animation itself as the visual every step pins. No figure index, no
    /// PDF, no resolver; the page is pointed at through the focus handler.
    /// False when the animation has no usable walkthrough, or when this chat
    /// is a conversation the walk is no part of.
    @discardableResult
    func loadWalkthrough(forAnimation artifact: ArtifactRecord) async -> Bool {
        await whileOpeningWalkthrough(artifact.id) {
            guard let loaded = try? await storage.loadArtifactWalkthrough(artifact.id), loaded.isUsable else {
                if walkthroughPlayback?.sourceID == artifact.id { clearWalkthroughPlayback() }
                return false
            }
            return await installWalkthroughPlayback(subject: .animation(artifact), loaded: loaded, figures: [], pdfPath: nil)
        }
    }

    /// Reload whatever this chat is playing, after the record changed.
    func reloadWalkthrough() async {
        guard let playback = walkthroughPlayback else { return }
        switch playback.subject {
        case .source(let article): await loadWalkthrough(for: article)
        case .animation(let artifact): await loadWalkthrough(forAnimation: artifact)
        }
    }

    /// Installs or refreshes the playback for `subject`, keeping the place
    /// the learner was at, and loads the records of every saved animation the
    /// steps refer to so their cards know the pages to show. A walk not
    /// playing here yet is installed only where `chatTakesWalkthrough` lets
    /// it, decided after the last read so nothing lands in between; false,
    /// and nothing changed, when it does not.
    private func installWalkthroughPlayback(
        subject: WalkthroughPlayback.Subject,
        loaded: PaperWalkthrough,
        figures records: [PaperFigureRecord],
        pdfPath path: String?
    ) async -> Bool {
        var animations: [String: ArtifactRecord] = [:]
        for id in loaded.referencedAnimationIDs {
            if let own = subject.animation, own.id == id { animations[id] = own; continue }
            if let record = try? await storage.loadArtifact(id) { animations[id] = record }
        }
        if var playback = walkthroughPlayback, playback.sourceID == subject.id {
            adoptWalkthroughResolver(for: subject, figures: records, pdfPath: path)
            playback.walkthrough = loaded
            playback.figures = records
            playback.pdfPath = path
            playback.animations = animations
            playback.currentIndex = min(playback.currentIndex, max(0, loaded.steps.count - 1))
            // Only a changed record is written back, so a reload that finds
            // the walk as it was leaves the card's views alone.
            if playback != walkthroughPlayback { walkthroughPlayback = playback }
        } else {
            // Where the learner is comes from the walk's own record. A walk
            // played in a chat before that record existed is taken up from
            // the chat's step turns, and the record is written from them the
            // first time the walk moves.
            let stored: WalkthroughProgress?
            do {
                stored = try await storage.loadWalkthroughProgress(subject.id)
            } catch {
                logger.error("Failed to load walkthrough progress for \(subject.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                stored = nil
            }
            guard chatTakesWalkthrough(of: subject.id, walkChatID: stored?.chatSessionID) else {
                logger.info("Walkthrough \(subject.id, privacy: .public) not opened over a chat it is no part of")
                return false
            }
            adoptWalkthroughResolver(for: subject, figures: records, pdfPath: path)
            let markers = chatMessages.compactMap(\.walkthroughStep).filter { $0.sourceID == subject.id }
            var playback = WalkthroughPlayback(
                subject: subject,
                walkthrough: loaded,
                figures: records,
                pdfPath: path,
                animations: animations,
                currentIndex: min(markers.last?.index ?? 0, max(0, loaded.steps.count - 1)),
                playedStepIDs: Set(markers.map(\.stepID))
            )
            let progress = stored ?? WalkthroughProgress.seeded(
                subjectID: subject.id,
                markers: markers,
                chatSessionID: sessionID
            )
            if let progress { playback.adopt(progress) }
            // A chat that is already this walk's own takes its questions.
            if playback.chatSessionID == nil, !markers.isEmpty { playback.chatSessionID = sessionID }
            persistedWalkthroughProgress = stored
            walkthroughPlayback = playback
        }
        return true
    }

    /// Whether `subjectID`'s walk may start playing over what this chat
    /// holds: nothing yet, or a chat that is already the walk's own — its
    /// cards are in the transcript, or it is the chat the walk's questions go
    /// to (`walkChatID`, from the walk's record). Never a conversation the
    /// walk is no part of, nor a chat still being reopened here: the card
    /// sat above a search the learner had typed in an unrelated chat, the
    /// whole of it drawn as the card's thread because none of its turns was a
    /// card (product owner, 2026-09-30: "a walkthrough got mixed with a chat").
    func chatTakesWalkthrough(of subjectID: String, walkChatID: String? = nil) -> Bool {
        if chatMessages.contains(where: { $0.walkthroughStep?.sourceID == subjectID }) { return true }
        if let walkChatID, sessionID == walkChatID { return true }
        return !hasConversation && !isResumingSession
    }

    /// The anchor geometry for the walk about to play: a source walk keeps
    /// its resolver, and what it has resolved, while the figure index and the
    /// PDF are the ones it was built from; an animation walk has none.
    private func adoptWalkthroughResolver(
        for subject: WalkthroughPlayback.Subject,
        figures records: [PaperFigureRecord],
        pdfPath path: String?
    ) {
        let sameWalk = walkthroughPlayback?.sourceID == subject.id
        switch subject {
        case .source:
            if sameWalk, walkthroughResolver?.matches(figures: records, pdfPath: path) == true { return }
            walkthroughResolver = WalkthroughAnchorResolver(figures: records, pdfPath: path)
        case .animation:
            if sameWalk { return }
            walkthroughResolver = nil
        }
        walkthroughResolvedByStep = [:]
        walkthroughCardPictureByStep = [:]
    }

    func clearWalkthroughPlayback() {
        walkthroughPlayback = nil
        walkthroughResolvedByStep = [:]
        walkthroughCardPictureByStep = [:]
        walkthroughChosenPanel = [:]
        walkthroughResolver = nil
    }

    /// The strip's ×: the learner leaves the walk (product owner, 2026-09-21: "I'm
    /// not seeing any press X to close in the top right here for this
    /// walkthrough"). The record is let go and the outline on the page comes
    /// down; the steps already played stay in the chat, because leaving a walk
    /// is not undoing it, and fold in the transcript to one row that resumes
    /// the walk (`WalkthroughTranscriptFold.resting`). The chat carries on as
    /// an ordinary conversation about the source, and reopening it picks the
    /// walk back up from those turns, the way any resumed walk does.
    func leaveWalkthroughPlayback() {
        guard walkthroughPlayback != nil else { return }
        clearWalkthroughPlayback()
        walkthroughStepScrollRequest = nil
        walkthroughFocusHandler?(.clear)
    }

    /// A chat starting on this manager keeps a loaded walk only when the walk
    /// is about what the chat is about. A walk can load into an empty chat and
    /// never play a step — its first step waits on a session that could not be
    /// made — and the chat started there next inherited its strip: a chat
    /// about an article opened under a paper's walkthrough (product owner,
    /// 2026-09-23: "clearly it still has some walkthrough/lesson stuff from a
    /// previous session at the top"). A walk whose steps are already in the
    /// transcript is this chat's own and stays.
    func releaseWalkthroughPlaybackForNewChat(about articles: [StudioArticle]) {
        guard let playback = walkthroughPlayback else { return }
        if chatMessages.contains(where: { $0.walkthroughStep?.sourceID == playback.sourceID }) { return }
        if !playback.aboutSourceIDs.isDisjoint(with: articles.map(\.id)) { return }
        leaveWalkthroughPlayback()
    }

    /// A chat reopened on this manager keeps a loaded walk only when it is
    /// the walk's own: the chat the walk's questions go to, or one holding its
    /// cards. Any other chat would be drawn whole under the walk's card, since
    /// none of its turns is a card (product owner, 2026-09-30: "a walkthrough got
    /// mixed with a chat"). The previous-chats list and a Resume suggestion
    /// reopen a chat on the pane's own manager, where a walk may be dealing
    /// cards with no chat of its own. Its place stays in its record.
    func releaseWalkthroughPlaybackForReopenedChat(_ reopenedSessionID: String) {
        guard let playback = walkthroughPlayback, playback.chatSessionID != reopenedSessionID else { return }
        if chatMessages.contains(where: { $0.walkthroughStep?.sourceID == playback.sourceID }) { return }
        leaveWalkthroughPlayback()
    }

    /// Names the wait for the duration of `work`. Nested (a step shown through
    /// a load) keeps the inner name while it runs and puts the outer one back
    /// after.
    private func withWalkthroughPreparation<T>(_ detail: String, _ work: () async -> T) async -> T {
        let outer = walkthroughPreparationDetail
        walkthroughPreparationDepth += 1
        walkthroughPreparationDetail = detail
        defer {
            walkthroughPreparationDepth -= 1
            walkthroughPreparationDetail = walkthroughPreparationDepth > 0 ? outer : nil
        }
        return await work()
    }

    /// Names the wait for a walk being opened. The walk this chat already
    /// plays is read again unnamed: any synced change to a source or an
    /// artifact reloads it (`StudioViewModel.noteWalkthroughChanged`), and a
    /// named reload dropped the stage for the compact card and a working line
    /// and then put it back, so the card flickered between its two layouts
    /// while the learner sat reading it (product owner, 2026-09-29: "this is acting
    /// weird and jittering occasionally … should just be stable").
    private func whileOpeningWalkthrough<T>(_ subjectID: String, _ work: () async -> T) async -> T {
        if walkthroughPlayback?.sourceID == subjectID { return await work() }
        return await withWalkthroughPreparation("Opening the walkthrough", work)
    }

    /// A reopened chat whose turns carry step lines picks its walk back up:
    /// the record loads, the header strip returns, and Back, Next and the
    /// chips work. Nothing is focused until the learner asks. The walk's
    /// source is looked up in the library when the chat no longer has it
    /// attached: a restore that quietly gave up left the step turns drawn as
    /// plain replies (product owner, 2026-09-23: "why is a walkthrough with cards
    /// still kind of a chat?").
    func restoreWalkthroughPlaybackIfNeeded() async {
        guard walkthroughPlayback == nil,
              let marker = chatMessages.compactMap(\.walkthroughStep).last else { return }
        if let article = activeArticles.first(where: { $0.id == marker.sourceID }) {
            await loadWalkthrough(for: article)
        } else if let article = try? await storage.loadSourceWithoutContent(marker.sourceID) {
            await loadWalkthrough(for: article)
        } else if let artifact = try? await storage.loadArtifact(marker.sourceID), artifact.isAnimation {
            await loadWalkthrough(forAnimation: artifact)
        }
    }

    /// Deals the step at `index`: its first card goes up, the Reader is
    /// pointed at it and its neighbours are warmed. No model call, and no
    /// chat: the step becomes a turn of the walk's chat only when the learner
    /// asks about it (`bringWalkthroughCardIntoChat`); where they are is kept
    /// in the walk's own record. A step already dealt is pointed at again,
    /// and a step already being dealt is left to that call.
    func playWalkthroughStep(at index: Int) async {
        guard let playback = walkthroughPlayback, playback.steps.indices.contains(index) else { return }
        let stepID = playback.steps[index].id
        if playback.playedStepIDs.contains(stepID) {
            await showWalkthroughStep(at: index)
            return
        }
        guard walkthroughStepsBeingPlayed.insert(stepID).inserted else { return }
        defer { walkthroughStepsBeingPlayed.remove(stepID) }
        let wasDealt = await withWalkthroughPreparation("Getting step \(index + 1) ready") { () async -> Bool in
            guard let playback = walkthroughPlayback, playback.steps.indices.contains(index) else { return false }
            let step = playback.steps[index]
            guard step.id == stepID, !playback.playedStepIDs.contains(step.id) else { return false }
            // The step lands at its first beat, pointed where that beat
            // points.
            walkthroughPlayback?.revealedBeats[step.id] = 1
            let resolved = await resolveWalkthroughAnchor(for: step)
            guard var dealt = walkthroughPlayback, dealt.sourceID == playback.sourceID else { return false }
            dealt.playedStepIDs.insert(step.id)
            dealt.currentIndex = index
            walkthroughPlayback = dealt
            await applyWalkthroughFocus(resolved, step: step)
            requestWalkthroughStepScroll(to: step.id)
            return true
        }
        // After the named wait: the card is up, and the learner is not
        // waiting on the steps either side of it.
        if wasDealt { await prefetchWalkthroughNeighbours(of: index) }
    }

    /// Adds the step's turn to the walk's chat and saves it: the marker line
    /// the card thread keys on, and the step's words, which are what the
    /// tutor reads when the learner asks about the card. Only ever ahead of a
    /// question (`bringWalkthroughCardIntoChat`).
    private func appendWalkthroughStepTurn(
        _ step: PaperWalkthroughStep,
        at index: Int,
        resolved: WalkthroughResolvedAnchor?,
        playback: WalkthroughPlayback
    ) async {
        let marker = WalkthroughStepTurn.Marker(
            sourceID: playback.sourceID,
            stepID: step.id,
            index: index,
            count: playback.steps.count
        )
        let markdown = WalkthroughStepComposer.markdown(
            step: step,
            marker: marker,
            lens: WalkthroughStepComposer.lensReference(
                sourceID: playback.sourceID,
                resolved: resolved,
                readerBesideChatShowsSource: readerBesideChatShows(playback.sourceID)
            )
        )
        chatMessages.append(contentsOf: assistantMessages(
            splitting: markdown,
            finalID: nil,
            createdAt: Date(),
            exchangeID: nil,
            exchangeField: .question,
            modelProvider: nil,
            modelID: nil
        ))
        if let sessionID {
            do {
                let refs = playback.article.map { [$0.id] } ?? playback.subject.animation?.sourceIDs ?? []
                try await storage.addReviewPrompt(sessionID: sessionID, question: markdown, sourceRefs: refs)
            } catch {
                logger.error("Failed to persist walkthrough step \(step.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Before the learner's message goes from a card: the walk's chat is
    /// made if this is its first question, and the card's turn is added, so
    /// the message and its reply belong to the card they were asked on — the
    /// deck shows each card's own conversation
    /// (`WalkthroughTranscriptFold.cardThread`) — and the tutor reads the
    /// card's words right above the question (product owner, 2026-09-22: chat with
    /// a card "at all times"). The card the transcript ended on already owns
    /// what comes next and adds nothing. The chat is the walk's attachment
    /// for questions, never where the walk is kept (walkthrough-design.md,
    /// "the walk leaves the chat").
    func bringWalkthroughCardIntoChat() async {
        guard let playback = walkthroughPlayback,
              let step = playback.currentStep,
              playback.playedStepIDs.contains(step.id) else { return }
        let last = chatMessages.compactMap(\.walkthroughStep).last
        if let last, last.sourceID == playback.sourceID, last.stepID == step.id { return }
        guard await ensureWalkthroughSession(for: playback) else { return }
        guard walkthroughPlayback?.sourceID == playback.sourceID else { return }
        if walkthroughPlayback?.chatSessionID != sessionID {
            walkthroughPlayback?.chatSessionID = sessionID
        }
        await appendWalkthroughStepTurn(
            step,
            at: playback.currentIndex,
            resolved: walkthroughResolvedByStep[step.id],
            playback: playback
        )
        if let quiz = step.quiz { lastAssistantQuestion = quiz.question }
    }

    /// A question card's Show Answer. A prediction's data come out from
    /// under the veil with it.
    func revealWalkthroughAnswer() {
        guard let step = walkthroughPlayback?.currentStep, let quiz = step.quiz,
              walkthroughPlayback?.recall[step.id] == nil else { return }
        walkthroughPlayback?.recall[step.id] = .revealed
        if quiz.kind == .predict || quiz.kind == .find { Task { await refreshWalkthroughFocus() } }
    }

    /// A question card graded by the learner after seeing the answer. Kept in
    /// the walk's own record, and as a Memory attempt on the question, so a
    /// question forgotten comes back in spaced review (quantum.country's
    /// mnemonic medium, which the 2026-09-22 deck left as "not yet"). No
    /// model call and no chat: a self-grade needs no tutor, and typing an
    /// answer in the walk's chat still gets one graded.
    func gradeWalkthroughRecall(remembered: Bool) async {
        guard let playback = walkthroughPlayback, let step = playback.currentStep,
              let quiz = step.quiz, playback.recall[step.id] == .revealed else { return }
        await recordWalkthroughRecall(
            step: step,
            quiz: quiz,
            outcome: remembered ? .remembered : .forgot,
            answer: remembered ? "I had it." : "I didn't have it.",
            evaluation: WalkthroughStepComposer.recallRecord(quiz: quiz, remembered: remembered),
            score: remembered ? 1 : 0,
            rating: remembered ? .good : .again
        )
    }

    /// What every self-graded card leaves behind: its outcome in the walk's
    /// record (saved by `walkthroughPlayback`'s observer), and the attempt
    /// on the question's Memory item.
    private func recordWalkthroughRecall(
        step: PaperWalkthroughStep,
        quiz: PaperWalkthroughQuiz,
        outcome: WalkthroughRecall,
        answer: String,
        evaluation: String,
        score: Double,
        rating: MemoryScheduleRating
    ) async {
        guard let playback = walkthroughPlayback else { return }
        walkthroughPlayback?.recall[step.id] = outcome
        walkthroughPlayback?.answeredQuizStepIDs.insert(step.id)
        guard let article = playback.article else { return }
        var question = SourceMemoryQuestion(
            sourceID: article.id,
            step: step,
            quiz: quiz,
            testing: playback.walkthrough.stepsBefore(question: step.id)
        )
        // A miss keeps a card, which shows the picture the walk showed the
        // question with; a question remembered first time keeps nothing.
        if rating != .good, rating != .easy {
            question.frontImages = await Self.walkthroughCardImages(
                step: step,
                walkthrough: playback.walkthrough,
                article: article
            )
        }
        do {
            try await storage.recordSourceQuestionAttempt(
                question,
                answer: answer,
                feedback: evaluation,
                score: score,
                rating: rating
            )
        } catch {
            // The grade stays on the card and in the walk's record; only the
            // question's return in spaced review is lost, and said so here.
            logger.error("Walkthrough question \(step.id, privacy: .public) is not in Memory: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The picture a walkthrough question's card keeps: the step's card
    /// picture, a figure read off the paper's file on this Mac (off the main
    /// actor, as card drafting reads it) or a picture drawn for the walk.
    /// Empty when the step has none, or its figure's file is not here.
    private static func walkthroughCardImages(
        step: PaperWalkthroughStep,
        walkthrough: PaperWalkthrough,
        article: StudioArticle
    ) async -> [MemoryCardImage] {
        guard let picture = walkthrough.cardPicture(of: step) else { return [] }
        var figures: [CourseQuizFigure] = []
        if case .drawn = picture {} else {
            let sourceID = article.id
            let filePath = article.resolvedFileLocation
            figures = await Task.detached(priority: .utility) {
                CourseQuizGeneratorService.readingFigures(sourceID: sourceID, filePath: filePath, pages: nil)
            }.value
        }
        return CardDraftingPictures.walkImage(picture, anchorLabel: step.anchor?.figureLabel, in: figures).map { [$0] } ?? []
    }

    /// The card on screen resolves its anchor for its picture without moving
    /// the Reader: a reopened chat focuses nothing until the learner asks,
    /// but the card still shows its figure. A card whose picture is a figure
    /// the step does not outline has that figure resolved too.
    func prepareCurrentWalkthroughCard() async {
        guard let playback = walkthroughPlayback, let step = playback.currentStep else { return }
        if walkthroughResolvedByStep[step.id] == nil {
            _ = await resolveWalkthroughAnchor(for: step)
        }
        guard walkthroughCardPictureByStep[step.id] == nil,
              case .figure(let anchor)? = playback.walkthrough.cardPicture(of: step),
              let article = playback.article,
              WalkthroughAnchorResolver.readerShowsPDF(article),
              let resolver = walkthroughResolver,
              let resolved = await resolver.resolve(anchor) else { return }
        // The walk may have moved on or been replaced while this resolved.
        guard walkthroughPlayback?.sourceID == playback.sourceID else { return }
        walkthroughCardPictureByStep[step.id] = resolved
    }

    /// Back: the step's previous beat, or, on its first, the previous step,
    /// pointed at again without another turn and shown as far as it was read.
    func walkthroughBack() async {
        guard let playback = walkthroughPlayback, playback.canGoBack else { return }
        if let step = playback.currentStep, playback.playedStepIDs.contains(step.id) {
            let revealed = playback.revealedBeatCount(of: step)
            if revealed > 1 {
                walkthroughPlayback?.revealedBeats[step.id] = revealed - 1
                await followWalkthroughBeat(of: step)
                return
            }
        }
        guard playback.currentIndex > 0 else { return }
        await showWalkthroughStep(at: playback.currentIndex - 1)
    }

    /// Next: the step's next beat while it has one — the page stays where
    /// the step put it — then the following step, played when it is not in
    /// the transcript yet, pointed at again when Back had left it behind.
    func walkthroughNext() async {
        guard let playback = walkthroughPlayback, playback.canGoNext else { return }
        if playback.currentStepHasBeatsLeft, let step = playback.currentStep {
            walkthroughPlayback?.revealedBeats[step.id] = playback.revealedBeatCount(of: step) + 1
            await followWalkthroughBeat(of: step)
            return
        }
        guard playback.currentIndex + 1 < playback.steps.count else { return }
        await showWalkthroughStep(at: playback.currentIndex + 1)
    }

    /// After a beat is shown or taken back: when the step's beats point at
    /// panels, the page follows the newest shown beat that points somewhere
    /// — a panel the learner picked by its chip gives way to it.
    private func followWalkthroughBeat(of step: PaperWalkthroughStep) async {
        guard let playback = walkthroughPlayback,
              playback.walkthrough.playableBeats(of: step).contains(where: { $0.anchor != nil }) else { return }
        walkthroughChosenPanel[step.id] = nil
        let resolved = await resolveWalkthroughAnchor(for: step)
        await applyWalkthroughFocus(resolved, step: step)
    }

    /// The anchor of the newest beat shown so far that has one; nil when
    /// none of them points anywhere of its own.
    private func walkthroughBeatAnchor(for step: PaperWalkthroughStep) -> PaperWalkthroughAnchor? {
        guard let playback = walkthroughPlayback else { return nil }
        let shown = playback.revealedBeatCount(of: step)
        return playback.walkthrough.playableBeats(of: step).prefix(shown).last(where: { $0.anchor != nil })?.anchor
    }

    /// Moves to a step: one already in the transcript is pointed at again; one
    /// not yet shown is played.
    func showWalkthroughStep(at index: Int) async {
        guard let playback = walkthroughPlayback, playback.steps.indices.contains(index) else { return }
        guard playback.playedStepIDs.contains(playback.steps[index].id) else {
            await playWalkthroughStep(at: index)
            return
        }
        let wasShown = await withWalkthroughPreparation("Getting step \(index + 1) ready") { () async -> Bool in
            guard let playback = walkthroughPlayback, playback.steps.indices.contains(index) else { return false }
            let step = playback.steps[index]
            guard playback.playedStepIDs.contains(step.id) else { return false }
            walkthroughPlayback?.currentIndex = index
            let resolved = await resolveWalkthroughAnchor(for: step)
            await applyWalkthroughFocus(resolved, step: step)
            requestWalkthroughStepScroll(to: step.id)
            return true
        }
        if wasShown { await prefetchWalkthroughNeighbours(of: index) }
    }

    /// The row's anchor chip or a panel letter: point the Reader at the step
    /// again, at `panel` when one was picked ("" for the whole figure).
    func refocusWalkthroughStep(id stepID: String, panel: String? = nil) async {
        guard let playback = walkthroughPlayback,
              let index = playback.steps.firstIndex(where: { $0.id == stepID }) else { return }
        if let panel { walkthroughChosenPanel[stepID] = panel }
        walkthroughPlayback?.currentIndex = index
        let step = playback.steps[index]
        let resolved = await resolveWalkthroughAnchor(for: step)
        await applyWalkthroughFocus(resolved, step: step)
    }

    /// What rides beside the learner's next message when the newest step in
    /// the transcript asks a question they have not answered: the grading
    /// brief, so the tutor's reply is the grade. Consumed on the first send;
    /// a second message about the same step is a follow-up, not another
    /// answer.
    func takeWalkthroughAnswerContext() -> String? {
        guard var playback = walkthroughPlayback,
              let marker = chatMessages.compactMap(\.walkthroughStep).last,
              marker.sourceID == playback.sourceID,
              let step = playback.step(id: marker.stepID),
              let quiz = step.quiz,
              !playback.answeredQuizStepIDs.contains(step.id) else { return nil }
        playback.answeredQuizStepIDs.insert(step.id)
        // The typed answer is the grade's; the card shows the reference
        // answer and asks for no self-grade, and a prediction's veil lifts.
        if playback.recall[step.id] == nil { playback.recall[step.id] = .answered }
        walkthroughPlayback = playback
        if quiz.kind == .predict || quiz.kind == .find { Task { await refreshWalkthroughFocus() } }
        return WalkthroughStepComposer.gradingContext(step: step, quiz: quiz, marker: marker)
    }

    /// The step's anchor resolved through the walk's resolver, at the panel
    /// the learner picked when they picked one; remembered for the row.
    private func resolveWalkthroughAnchor(for step: PaperWalkthroughStep) async -> WalkthroughResolvedAnchor? {
        guard let playback = walkthroughPlayback, let article = playback.article,
              WalkthroughAnchorResolver.readerShowsPDF(article),
              let resolver = walkthroughResolver else { return nil }
        let choice = walkthroughChosenPanel[step.id]
        if choice == nil, let beatAnchor = walkthroughBeatAnchor(for: step) {
            let ownFigure = step.anchor?.figureLabel.map(PaperWalkthroughValidation.canonicalLabel)
            if let ownFigure, beatAnchor.figureLabel.map(PaperWalkthroughValidation.canonicalLabel) == ownFigure {
                // Another panel of the step's own figure: the row's chips
                // follow, as they do when the learner picks the panel.
                let resolved = await resolver.resolve(beatAnchor)
                walkthroughResolvedByStep[step.id] = resolved
                return resolved
            }
            // Another figure altogether: the page goes there, and the row
            // keeps naming the step's own.
            return await resolver.resolve(beatAnchor)
        }
        let resolved = await resolver.resolve(step.anchor, panel: choice)
        if let resolved {
            walkthroughResolvedByStep[step.id] = resolved
        } else {
            walkthroughResolvedByStep[step.id] = nil
        }
        return resolved
    }

    private func prefetchWalkthroughNeighbours(of index: Int) async {
        guard let playback = walkthroughPlayback, let article = playback.article, let resolver = walkthroughResolver,
              WalkthroughAnchorResolver.readerShowsPDF(article) else { return }
        let neighbours = [index - 1, index + 1]
            .filter { $0 >= 0 && $0 < playback.steps.count }
            .map { playback.steps[$0].anchor }
        // The beats of this step that point elsewhere are the next moves.
        let beats = playback.steps.indices.contains(index)
            ? playback.walkthrough.playableBeats(of: playback.steps[index]).compactMap(\.anchor)
            : []
        await resolver.prefetch(neighbours + beats)
    }

    /// Points the Reader at a step. On a PDF the step is a standing focus the
    /// page keeps outlined; a source shown as text has no page to outline on,
    /// so a passage step takes the route a chat citation takes: the reader
    /// scrolls to the passage and flashes it. A video's step holds the player
    /// at its moment, paused, so the card is read over what the talk showed
    /// then.
    private func applyWalkthroughFocus(_ resolved: WalkthroughResolvedAnchor?, step: PaperWalkthroughStep) async {
        guard let playback = walkthroughPlayback else { return }
        let sourceID = playback.sourceID
        // A step that shows a saved animation points every pane showing that
        // animation at the step, the way a figure step outlines the figure;
        // the walk's own outline on a source, if any, comes down.
        if let reference = step.animation {
            walkthroughFocusHandler?(.animation(artifactID: reference.animationID, step: reference.step, conditions: reference.conditions))
            return
        }
        guard let article = playback.article else {
            walkthroughFocusHandler?(.clear)
            return
        }
        guard WalkthroughAnchorResolver.readerShowsPDF(article) else {
            if let seconds = step.anchor?.seconds, article.isYouTubeURL {
                walkthroughFocusHandler?(.moment(seconds: seconds, sourceID: sourceID))
            } else if let passage = step.anchor?.passage?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty {
                walkthroughFocusHandler?(.flash(passage: passage, sourceID: sourceID))
            } else {
                walkthroughFocusHandler?(.clear)
            }
            return
        }
        guard let resolved else {
            walkthroughFocusHandler?(.clear)
            return
        }
        // A question card's page (the lesson's emphasis, merged 2026-09-23):
        // a prediction still waiting for its guess covers the panel's data;
        // a Find it makes each panel a click target where the index has its
        // rectangle. Answered, both are outlined as any step is.
        let onQuestionCard = playback.currentBeat(of: step)?.kind == .question
        if onQuestionCard, let quiz = step.quiz, playback.recall[step.id] == nil {
            switch quiz.kind {
            case .predict:
                walkthroughFocusHandler?(.spotlight(resolved.target, stepID: step.id, sourceID: sourceID, veiled: true))
                return
            case .find:
                if let resolver = walkthroughResolver, case .figure(let pageIndex, _, _, _) = resolved.target {
                    var pickable: [ReaderWalkthroughFocus.PickablePanel] = []
                    for label in resolved.panelLabels {
                        guard let target = await resolver.resolve(step.anchor, panel: label)?.target,
                              case .figure(let panelPage, let rect?, _, _) = target,
                              panelPage == pageIndex else { continue }
                        pickable.append(ReaderWalkthroughFocus.PickablePanel(label: label, rect: rect))
                    }
                    if !pickable.isEmpty {
                        walkthroughFocusHandler?(.pickPanel(resolved.target, stepID: "\(step.id)#pick", sourceID: sourceID, panels: pickable))
                        return
                    }
                }
            case .recall, .thinkFirst:
                break
            }
        }
        walkthroughFocusHandler?(.outline(resolved.target, stepID: step.id, sourceID: sourceID))
    }

    /// Points the page at the current step again, as the card stands now:
    /// after Show answer or a typed answer lifts a prediction's veil, or a
    /// pick settles a Find it.
    private func refreshWalkthroughFocus() async {
        guard let playback = walkthroughPlayback, let step = playback.currentStep else { return }
        let resolved: WalkthroughResolvedAnchor?
        if let cached = walkthroughResolvedByStep[step.id] {
            resolved = cached
        } else {
            resolved = await resolveWalkthroughAnchor(for: step)
        }
        await applyWalkthroughFocus(resolved, step: step)
    }

    /// A Find it card answered on the figure — the panel's letter or name,
    /// from the card's chips or a click on the page
    /// (`readerPanelPickHandler`). Right first time is remembered; a wrong
    /// pick gets one more try, then the answer shows as a miss. Saved as the
    /// recall grades are.
    func pickWalkthroughPanel(sourceID: String, panel: String) async {
        guard let playback = walkthroughPlayback, playback.sourceID == sourceID,
              let step = playback.currentStep, let quiz = step.quiz, quiz.kind == .find,
              let target = quiz.targetPanel, playback.recall[step.id] == nil else { return }
        let correct = PaperWalkthroughValidation.samePanel(panel, target)
        let misses = walkthroughFindMisses[step.id] ?? 0
        if !correct, misses == 0 {
            walkthroughFindMisses[step.id] = 1
            return
        }
        walkthroughFindMisses[step.id] = nil
        await recordWalkthroughRecall(
            step: step,
            quiz: quiz,
            outcome: correct ? .remembered : .forgot,
            answer: "Panel \(PaperWalkthroughValidation.panelDisplayName(panel))",
            evaluation: WalkthroughStepComposer.findRecord(quiz: quiz, picked: panel, correct: correct),
            score: correct ? (misses == 0 ? 1 : 0.5) : 0,
            rating: correct ? (misses == 0 ? .good : .hard) : .again
        )
        await refreshWalkthroughFocus()
    }

    /// A chat playing a walk needs a session row for the steps to be
    /// persisted into, and the source attached so the tutor can answer what
    /// is typed between them. Mirrors `startSession`'s prologue without its
    /// opening turn: creating the row spends nothing.
    private func ensureWalkthroughSession(for playback: WalkthroughPlayback) async -> Bool {
        // The sources the chat attaches: the source itself, or the sources an
        // animation is about (its grounding), so the tutor can answer what is
        // typed between the steps from the papers the animation explains.
        let articles: [StudioArticle]
        switch playback.subject {
        case .source(let article): articles = [article]
        case .animation(let artifact):
            let ids = artifact.sourceIDs
            articles = ids.isEmpty ? [] : ((try? await storage.loadPersistedSources(ids: ids)) ?? [])
        }
        if sessionID != nil || sessionActive {
            let missing = articles.filter { !activeSourceIDs.contains($0.id) }
            if !missing.isEmpty { await addContextSources(missing) }
            return true
        }
        topic = playback.isAnimationWalk
            ? playback.walkthrough.title
            : reviewTitle(topic: playback.walkthrough.title, articles: articles)
        titleIsProvisional = false
        sessionPromptKind = InitialPromptMode.review.sessionPromptKindForUserMessage
        errorMessage = nil
        lastGenerationFailed = false
        completedSummary = nil
        isSearching = true
        if !articles.isEmpty {
            let context = await loadSourceContext(from: articles)
            guard !context.readableSourceIDs.isEmpty || playback.isAnimationWalk else {
                isSearching = false
                errorMessage = "No readable source content is available for \"\(playback.subject.title)\". Fetch or import the source content before walking through it."
                return false
            }
            await refreshSourceContextBudgetFromSelectedModel()
            await applyAttachedSourceContext(context, articles: articles, preloading: Set(articles.map(\.id)))
        }
        isSearching = false
        let config = await Self.resolveChatConfig().config
        let id = UUID().uuidString
        do {
            try await storage.createReviewSession(
                id: id,
                topic: topic,
                sourceIDs: persistedSessionSourceIDs,
                cardIDs: [],
                modelProvider: config?.provider.rawValue,
                modelID: config?.model,
                goalID: nil,
                scheduleActivityAt: Date(),
                scheduleActivityKind: .reading,
                chatKind: .walkthrough
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to create the walkthrough's chat session: \(error.localizedDescription, privacy: .public)")
            return false
        }
        sessionID = id
        sessionActive = true
        beginSessionCostTracking()
        await persistLoadedSourceIDs()
        return true
    }

    // MARK: Focus as a chat tool

    /// `focus_source_anchor`: point the Reader at a figure, a panel, a passage
    /// or a page of a source, the way a played walkthrough step does. The
    /// anchor is checked against the source's figure index and text — the
    /// same check the record's validation runs — and refused when the source
    /// does not print it: "anchors are checked, never trusted" holds for a
    /// live tutor too.
    func focusSourceAnchor(arguments: [String: Any]) async -> AppToolResult {
        guard let requestedID = Self.nonEmptyTrimmed(arguments["source_id"] as? String) else {
            return AppToolResult(text: "Error: focus_source_anchor needs a source_id, from the attached catalog or a search result.", isError: true)
        }
        guard let article = await librarySourceArticle(forRequestedID: requestedID) else {
            return AppToolResult(text: Self.sourceNotInLibraryMessage(requestedID), isError: true)
        }
        // A video is pointed at by its moment: the Reader's player is sought
        // there, paused, as a video walk's step does. On 2026-11-07 a tutor
        // pointing at a passage of a recorded talk was refused with "is a
        // video", a failed row in the middle of its reply, though the talk's
        // transcript times every passage.
        if article.sourceType == .video {
            return await focusVideoMoment(article, arguments: arguments)
        }
        // A meeting's notes and a podcast's transcript are text the Reader
        // shows, so a passage copied from them is flashed like an article's;
        // they have no figures or pages to outline (a figure or page anchor
        // below is refused as "shown as text").
        let subject = PaperWalkthroughSubject.of(article)
        let isTranscriptText = subject == nil && (article.sourceType == .meeting || article.sourceType == .podcast)
        guard subject != nil || isTranscriptText else {
            return AppToolResult(
                text: "Error: \"\(article.title)\" is not a paper, a book chapter, an article, a meeting or a podcast; only those have a page or text the Reader can point at.",
                isError: true
            )
        }
        func integer(_ name: String) -> Int? {
            if let value = arguments[name] as? Int { return value }
            if let value = arguments[name] as? Double { return Int(value) }
            if let value = arguments[name] as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        var anchor = PaperWalkthroughAnchor(
            figureLabel: Self.nonEmptyTrimmed(arguments["figure_label"] as? String),
            panelLabel: Self.nonEmptyTrimmed(arguments["panel_label"] as? String),
            passage: Self.nonEmptyTrimmed(arguments["passage"] as? String),
            pageNumber: integer("page_number")
        )
        guard !anchor.isEmpty else {
            return AppToolResult(text: "Error: focus_source_anchor needs a figure_label, a passage copied from the source, or a page_number.", isError: true)
        }
        let sourceID = article.id
        var figures = (try? await storage.paperFigures(sourceID: sourceID)) ?? []
        var record: PaperFigureRecord?
        if let label = anchor.figureLabel {
            guard PaperWalkthroughSubject.allowsFigureAnchors(article) else {
                return AppToolResult(
                    text: "Error: \"\(article.title)\" is shown as text and has no figures to outline. Point at a passage copied from its text instead.",
                    isError: true
                )
            }
            // A paper's figure index is built the first time something asks
            // for it, and a paper nobody has asked about has none: on
            // 2026-10-28 "Figure 1" of a freshly imported preprint was refused
            // as "not found" with 700 papers still queued, though its caption
            // is printed. Reading the captions is free (no model, nothing
            // spent), so it is done here as inspect_paper_figure does it; a
            // failed read is reported as that, never as a missing figure.
            if figures.isEmpty {
                do {
                    figures = try await paperFigureIndexer.prepareStructure(sourceID: sourceID)
                } catch {
                    return AppToolResult(
                        text: "Error: the figures of \"\(article.title)\" could not be indexed: \(error.localizedDescription) Call show_source_image with this source_id and page set to a PDF page to show the picture from the paper itself.",
                        isError: true
                    )
                }
            }
            guard let found = WalkthroughAnchorResolver.figureRecord(labelled: label, in: figures) else {
                return AppToolResult(
                    text: Self.figureLabelNotFoundMessage(requested: label, availableLabels: figures.map(\.figureLabel)),
                    isError: true
                )
            }
            record = PaperWalkthroughGeneratorService.displayRecord(for: found, in: figures)
            anchor.figureLabel = found.figureLabel
            anchor.pageNumber = found.pageIndex + 1
        }
        if let passage = anchor.passage {
            let clipped = PaperWalkthroughValidation.clippedPassage(passage)
            let text = await storage.loadSourceContent(sourceID) ?? ""
            let normalizedText = PaperWalkthroughValidation.normalized(text)
            guard normalizedText.isEmpty || normalizedText.contains(PaperWalkthroughValidation.normalized(clipped)) else {
                return AppToolResult(
                    text: "Error: the passage is not in \"\(article.title)\" as written. Copy eight to thirty of the source's own words exactly, in order, and call again.",
                    isError: true
                )
            }
            anchor.passage = clipped
        }

        let path = (try? await storage.paperFigureIndexTarget(sourceID: sourceID))?.pdfPath
        let resolver: WalkthroughAnchorResolver
        if let held = walkthroughResolver, walkthroughPlayback?.sourceID == sourceID,
           held.matches(figures: figures, pdfPath: path) {
            resolver = held
        } else {
            resolver = WalkthroughAnchorResolver(figures: figures, pdfPath: path)
        }
        let showsPDF = WalkthroughAnchorResolver.readerShowsPDF(article)
        let resolved = showsPDF ? await resolver.resolve(anchor) : nil
        // Pointing a Reader that is not there shows nothing: open the source
        // beside the chat first — a paper to outline on, or an article whose
        // passage the Reader scrolls to and flashes — as inspect_paper_figure
        // does.
        let besideChat = resolved != nil || anchor.passage != nil
            ? await readerBesideChatShowsOpening(article)
            : readerBesideChatShows(sourceID)
        let stepID = "focus-\(UUID().uuidString)"
        if showsPDF, let resolved {
            walkthroughFocusHandler?(.outline(resolved.target, stepID: stepID, sourceID: sourceID))
        } else if let passage = anchor.passage {
            walkthroughFocusHandler?(.flash(passage: passage, sourceID: sourceID))
        } else if !showsPDF {
            return AppToolResult(
                text: "Error: \"\(article.title)\" is shown as text; only a passage copied from it can be pointed at.",
                isError: true
            )
        }

        let shownPanel = resolved?.panel ?? anchor.panelLabel
            .map(PaperWalkthroughValidation.panelDisplayName)
            .flatMap { $0.isEmpty ? nil : $0 }
        var lines: [String] = []
        if let record {
            let shownLabel = PaperWalkthroughValidation.figurePanelLabel(record.figureLabel, panel: shownPanel)
            var line = "Pointed the Reader at \(shownLabel) in \"\(article.title)\" (PDF page \(record.pageIndex + 1))"
            if let title = PaperFigureCaptionTitle.title(from: record.caption) { line += " — \(title)" }
            lines.append(line + ".")
            if let shownPanel, let caption = PaperFigureCaptionTitle.panelCaption(for: shownPanel, in: record.caption) {
                lines.append("Panel \(shownPanel): \(caption)")
            }
            if let resolved, !resolved.panelLabels.isEmpty {
                lines.append("Panels the figure offers: \(resolved.panelLabels.joined(separator: ", ")).")
            }
            if anchor.panelLabel != nil, resolved?.panel == nil {
                lines.append("The panel's own rectangle is not known, so the whole figure is outlined.")
            }
        } else if let passage = anchor.passage {
            lines.append("Pointed the Reader at the passage “\(passage)” in \"\(article.title)\"" + (showsPDF ? "; it is outlined on the page." : "; the Reader scrolled to it and flashed it."))
        } else if let page = anchor.pageNumber {
            lines.append("Pointed the Reader at page \(page) of \"\(article.title)\".")
        }
        if let lens = WalkthroughStepComposer.lensReference(
            sourceID: sourceID,
            resolved: resolved,
            readerBesideChatShowsSource: besideChat
        ), let record {
            lines.append("")
            lines.append(
                "Include this Markdown image line verbatim, on its own line, so the learner sees the panel enlarged in the reply: "
                + lens.markdown(alt: PaperWalkthroughValidation.figurePanelLabel(record.figureLabel, panel: shownPanel))
            )
        } else if resolved?.panel != nil, record != nil {
            lines.append("")
            lines.append("The learner's Reader is showing the panel outlined beside the chat, so do not add an image of it to the reply.")
        }
        return AppToolResult(text: lines.joined(separator: "\n"), isError: false)
    }

    /// `focus_source_anchor` on a video: open it beside the chat and seek its
    /// player to `at`, or to where its timed transcript says `passage` (a few
    /// seconds early, as a citation of the words opens it), paused. A video
    /// has no figures or pages; a passage the transcript does not say, or one
    /// of an untimed transcript, is refused with the way to name the moment.
    private func focusVideoMoment(_ article: StudioArticle, arguments: [String: Any]) async -> AppToolResult {
        if arguments["figure_label"] != nil || arguments["page_number"] != nil {
            return AppToolResult(
                text: "Error: \"\(article.title)\" is a video and has no figures or pages. Point at a moment: at (seconds or a clock reading such as 16:13), or a passage copied from its transcript.",
                isError: true
            )
        }
        let seconds: Int
        let passage = Self.nonEmptyTrimmed(arguments["passage"] as? String)
        if arguments["at"] != nil {
            guard let at = SourceImageReference.timestampSeconds(arguments["at"]) else {
                return AppToolResult(
                    text: "Error: at must be a time in the video — seconds (973) or a clock reading (16:13, 1:02:03).",
                    isError: true
                )
            }
            seconds = at
        } else if let passage {
            let content = await storage.loadSourceContent(article.id) ?? ""
            let timeline = LectureQuizTimeline(CourseQuizPlanning.lines(from: content))
            guard let said = timeline.seconds(saying: passage) else {
                return AppToolResult(
                    text: "Error: the passage is not in the timed transcript of \"\(article.title)\" as written. Copy eight to thirty of its own words exactly, in order, or pass at with the time of its [mm:ss] marker.",
                    isError: true
                )
            }
            seconds = Int(said)
        } else {
            return AppToolResult(
                text: "Error: focus_source_anchor on a video needs at (seconds or a clock reading) or a passage copied from its transcript.",
                isError: true
            )
        }
        _ = await readerBesideChatShowsOpening(article)
        walkthroughFocusHandler?(.moment(seconds: seconds, sourceID: article.id))
        let time = SlideFrameExtraction.displayTime(Double(seconds))
        return AppToolResult(
            text: "Pointed the Reader at \(time) in \"\(article.title)\"; the video is paused there. Cite the moment as [\(article.title)](foreverlm://source/\(article.id)?t=\(seconds)).",
            isError: false
        )
    }
}
