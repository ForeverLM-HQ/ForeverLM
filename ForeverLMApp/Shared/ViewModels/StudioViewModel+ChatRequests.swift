// Requests that open or reset the review chat in a window.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    /// Opens a saved chat in the window in scope. Which workspace it opens in
    /// follows the chat (`applyChatHome`): one filed in a notebook opens that
    /// notebook here, a library chat leaves the window's notebook.
    func requestResumeReviewSession(_ sessionID: String) {
        applyChatHome(forSessionID: sessionID, in: chatRequestOriginWindow ?? activeWindowState)
        reviewChatResumeSessionID = sessionID
        reviewChatPanelMode = .chat
        isChatTabActive = true
    }

    func requestResetReviewChat() {
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
    }

    /// Start a tutor review of a Notebook's approved sources from outside the
    /// chat panel: seeds the context, links the notebook (so completing the
    /// session records against it), and auto-starts the session. The reset
    /// request runs before the auto-start request in the panel's task order,
    /// so the notebook link is in place when the session begins.
    func requestNotebookReview(_ notebookID: String) {
        guard let notebook = notebook(id: notebookID) else { return }
        // Every box unticked: there is nothing to review, and the idle
        // composer's Start review says so in the same words.
        let tally = notebookChatTally(notebook)
        if tally.inChat == 0, tally.total > 0 {
            showToast("Tick a source in \u{201C}\(notebook.title)\u{201D} to review it.")
            return
        }
        pendingReviewChatNotebookID = notebook.id
        setContextSources(notebookChatSourceIDs(notebook))
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatAutoStartRequestID = UUID()
    }

    /// Records which window the chat request being made is for, and says so
    /// whenever that is not the window the request was made in.
    ///
    /// The destination is the window in scope — the key Studio window, or the
    /// one an `inWindow` scope names (`chatRequestDestinationWindow`). Only a
    /// request from a window that is no Studio window at all (a popped-out
    /// Reader) lands elsewhere, in the Studio window used last. The chat then
    /// appears on a display the learner may not be looking at, and a click
    /// whose result shows up somewhere else looks like a click that did
    /// nothing — so the toast names where it went. Called from the request
    /// tokens' `didSet`, so every requester is covered.
    func stampChatRequestTargetWindow() {
        let origin = chatRequestOriginWindow
        let destination = chatRequestDestinationWindow(origin: origin)
        reviewChatTargetWindowID = destination.id
        chatRequestElsewhereNotice = chatOpenedElsewhereNotice(origin: origin, destination: destination)
        if let chatRequestElsewhereNotice {
            let replay = ChatRequestReplay(
                resumeSessionID: reviewChatResumeSessionID,
                resetsChat: reviewChatResetRequestID != nil,
                autoStarts: reviewChatAutoStartRequestID != nil,
                notebookID: pendingReviewChatNotebookID,
                draft: pendingReviewChatDraft
            )
            showToast("Opened in \(chatRequestElsewhereNotice)", action: .openHere { [weak self] window in
                self?.replayChatRequest(replay, in: window)
            })
        }
    }

    /// What a chat request asked for, captured while its tokens are still
    /// set, so the toast's Open here can ask again in another window after
    /// the pane over there has consumed and cleared them.
    struct ChatRequestReplay: Equatable {
        var resumeSessionID: String?
        var resetsChat: Bool
        var autoStarts: Bool
        var notebookID: String?
        var draft: String?
    }

    /// Makes the chat request `replay` again, this time for `window`, from
    /// the toast's Open here. The request went elsewhere because it came from
    /// a popped-out Reader, and the button is the learner naming this window
    /// instead: Chat is revealed here first, releasing a pin if it has to, so
    /// the restamped request lands here and raises no second toast. The request is made inside the window's scope
    /// rather than the key window's: the button was pressed in this window,
    /// but the registry's notion of key can lag the click.
    func replayChatRequest(_ replay: ChatRequestReplay, in window: StudioWindowState) {
        activateCenterTab(.chat, in: window)
        inWindow(window) {
            reviewChatPanelMode = .chat
            isChatTabActive = true
            if replay.resetsChat {
                pendingReviewChatNotebookID = replay.notebookID
                pendingReviewChatDraft = replay.draft
                reviewChatResetRequestID = UUID()
            }
            if let sessionID = replay.resumeSessionID {
                reviewChatResumeSessionID = sessionID
            }
            if replay.autoStarts {
                reviewChatAutoStartRequestID = UUID()
            }
            reviewChatTargetWindowID = window.id
        }
    }

    /// The window a chat request made in `origin` should show in: always
    /// `origin`, the window the click was made in. It never goes to another
    /// window that happens to show Chat already, since sending it there is
    /// what the context menu's Open in Other Window is for (product owner,
    /// 2026-09-22: "no actual click on anything should ever open the thing in
    /// the other ForeverLM window"). A nil origin (no Studio window is key, as
    /// from a popped-out Reader) starts from the Studio window used last.
    func chatRequestDestinationWindow(origin: StudioWindowState?) -> StudioWindowState {
        origin ?? activeWindowState
    }

    /// Where the chat went, for the learner, when it is not the window the
    /// request was made in; nil when it shows in place. Only Studio windows on
    /// the registry count: the fallback scene tests and launch helpers navigate
    /// through is not a window on anyone's desk. From a window that is no
    /// Studio window the chat has always gone elsewhere, but with one Studio
    /// window open there is nowhere else it could have gone, so that says
    /// nothing; with two or more, it is one of several.
    private func chatOpenedElsewhereNotice(
        origin: StudioWindowState?,
        destination: StudioWindowState
    ) -> String? {
        let registered = StudioWindowRegistry.shared.states
        guard registered.contains(where: { $0 === destination }) else { return nil }
        if let origin {
            guard origin !== destination, registered.contains(where: { $0 === origin }) else { return nil }
            return Self.otherWindowDescription(otherWindowCount: registered.count - 1)
        }
        guard registered.count > 1 else { return nil }
        return Self.otherWindowDescription(otherWindowCount: registered.count)
    }

    /// "The other" is only honest while exactly one other Studio window is
    /// open; a second makes it one of several.
    static func otherWindowDescription(otherWindowCount: Int) -> String {
        otherWindowCount > 1 ? "another ForeverLM window" : "the other ForeverLM window"
    }

    /// Whether a primary Chat pane hosted in the window `ownerWindowID` should
    /// act on the pending global chat requests. A pane that does not know its
    /// window, and a request made before any was stamped, keep the old
    /// behaviour of accepting everything.
    func chatPaneAcceptsGlobalRequests(ownerWindowID: UUID?) -> Bool {
        guard let ownerWindowID, let reviewChatTargetWindowID else { return true }
        return ownerWindowID == reviewChatTargetWindowID
    }

    /// Pass a `notebookID` to start the fresh chat linked to that Notebook with the
    /// sources ticked in its pool as context (`notebookChatSourceIDs`). Nil
    /// asks for a library chat — Plan the Day, Getting Started, a scheduled
    /// task, a Goal chat with no Notebook — and a window holding a notebook
    /// leaves it first, as opening a library chat does (the chat-home rule,
    /// `applyChatHome`). New chat buttons ask through `requestNewChat`, which
    /// names the window's notebook.
    func requestBlankReviewChat(notebookID: String? = nil) {
        if notebookID == nil {
            closeNotebook(in: chatRequestOriginWindow ?? activeWindowState)
        }
        startBlankReviewChat(notebookID: notebookID)
    }

    /// The fresh chat `requestBlankReviewChat` and `requestNewChat` ask for,
    /// in whatever workspace the window is in: linked to `notebookID` with its
    /// ticked sources as context, or fully blank and unlinked.
    func startBlankReviewChat(notebookID: String?) {
        if let notebookID, let notebook = notebook(id: notebookID) {
            pendingReviewChatNotebookID = notebook.id
            setContextSources(notebookChatSourceIDs(notebook))
        } else {
            pendingReviewChatNotebookID = nil
            clearSourceContext()
        }
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// Open a fresh chat with the new-task template already typed but unsent.
    /// A scheduled task is a sentence ("every weekday at 7:30, quiz me on what I
    /// read yesterday"), not a set of fields, so the Tasks pane's "+" hands the
    /// learner to chat: the assistant asks for whatever the instruction and
    /// cadence still need and calls create_scheduled_task itself. The editor
    /// sheet stays for changing a task that already exists.
    func requestNewScheduledTaskChat() {
        pendingReviewChatDraft = "Set up a recurring scheduled task for me. Ask me what it should do and when it should run, then create it."
        requestBlankReviewChat()
    }

    /// Open a fresh chat that makes an animation. With a source, the chat
    /// starts with that source in context and the request typed but unsent —
    /// the source menu's Animate…; without one, the Animations home's button
    /// opens a blank chat with the request typed and the learner adds the
    /// source with /source. The chat draws the animation and saves it with
    /// save_animation, linked to the source (docs/animations-design.md).
    func requestAnimationChat(sourceID: String? = nil) {
        if let sourceID, let article = articles.first(where: { $0.id == sourceID }) {
            pendingReviewChatNotebookID = nil
            setContextSources([sourceID])
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: displayTitle(for: article))
            reviewChatPanelMode = .chat
            isChatTabActive = true
            reviewChatResetRequestID = UUID()
            reviewChatFocusRequestID = UUID()
        } else {
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: nil)
            requestBlankReviewChat()
        }
    }

    /// The unsent opening line for a chat that makes an animation. It names
    /// the source when there is one and leaves the mechanism to the learner:
    /// what to animate is the one thing only they can say.
    static func animationChatDraft(sourceTitle: String?) -> String {
        if let sourceTitle, !sourceTitle.isEmpty {
            return "Make an interactive animation of how the mechanism in \u{201C}\(sourceTitle)\u{201D} works — every step labelled and placed where it happens, with a toggle for each condition the paper compares — and save it with save_animation linked to this source. Animate: "
        }
        return "Make an interactive animation of how something works — every step labelled and placed where it happens, with a toggle for each condition compared — and save it with save_animation linked to the sources you draw it from. Animate: "
    }

    /// Opens the day-planning conversation with `request` unsent in the
    /// composer. The text is `ReviewSlashCommandParser.planDayRequest`, so the
    /// Today menu, the Now chip, "Plan your day?" and `/plan` all open the
    /// same conversation under the same rules rather than near-copies.
    func requestPlanDayChat(request: String) {
        pendingReviewChatDraft = request
        pendingPlanDayDraft = request
        requestBlankReviewChat()
    }

    /// The Feynman Technique on what the learner read recently, one click
    /// from the strip (product owner, 2026-11-24): a new library chat, the
    /// sources read, heard or watched yesterday and today as its context, or
    /// the past week's when those days had none, opening by asking the
    /// learner to explain one from memory (`TeachBack.recentOpeningMessage`).
    func requestRecentTeachBack() {
        closeNotebook(in: chatRequestOriginWindow ?? activeWindowState)
        reviewChatPanelMode = .chat
        isChatTabActive = true
        // The sources are read off the store, by which time the `inWindow`
        // scope the click opened is gone: remember the window now.
        let targetWindowID = (chatRequestOriginWindow ?? activeWindowState).id
        Task { [weak self] in
            guard let self else { return }
            guard let request = await recentTeachBackRequest() else {
                showToast("Nothing read, heard or watched this past week to explain yet.")
                return
            }
            pendingRecentTeachBack = request
            reviewChatAutoStartRequestID = UUID()
            reviewChatTargetWindowID = targetWindowID
        }
    }

    /// The sources a recent teach-back is about, from the Activity log of
    /// yesterday and today (else the past week): the time read, heard or
    /// watched on each plus the chats that discussed it, most time first
    /// (`TeachBack.recentEngagements`). Sources still in the library and not
    /// hidden; a book's chapter is named with its book. Nil when there are none.
    func recentTeachBackRequest(now: Date = Date()) async -> RecentTeachBackRequest? {
        let calendar = Calendar.current
        let today = DayPlan.dateString(for: now, calendar: calendar)
        var chatSources: [String: [String]] = [:]
        for (days, sinceYesterday) in [(TeachBack.recentDays, true), (TeachBack.widerRecentDays, false)] {
            guard let from = DayPlan.dateString(today, offsetBy: -(days - 1), calendar: calendar) else { continue }
            let plans = (try? await storage.loadDayPlans(from: from, to: today)) ?? []
            let activities = plans.flatMap(\.activities)
            for chatID in Set(activities.filter { $0.kind == .chat }.map(\.targetID)) where chatSources[chatID] == nil {
                chatSources[chatID] = (try? await storage.chatDiscussedSourceIDs(sessionID: chatID)) ?? []
            }
            let marks = await highlights(from: from, to: today)
            let ranked = TeachBack.recentEngagements(
                activities: activities,
                chatSources: chatSources,
                highlightCounts: marks.mapValues(\.count),
                isEligible: { id in articlesById[id].map(isSourceIncludedInKnowledge) ?? false },
                title: { id in articlesById[id]?.title ?? "" }
            )
            guard !ranked.sources.isEmpty else { continue }
            let lines = ranked.sources.map { entry in
                TeachBack.RecentLine(
                    title: articlesById[entry.sourceID].map(recentTeachBackTitle(for:)) ?? entry.sourceID,
                    minutes: entry.minutes,
                    chatTitles: entry.chatTitles,
                    highlights: entry.highlights
                )
            }
            return RecentTeachBackRequest(
                sourceIDs: ranked.sources.map(\.sourceID),
                lines: lines,
                otherChats: ranked.otherChats,
                sinceYesterday: sinceYesterday,
                highlightBriefing: highlightBriefing(ranked.sources.map(\.sourceID), marks: marks)
            )
        }
        return nil
    }

    /// The passages marked on each day from `from` to `to` (`YYYY-MM-DD`,
    /// both included), by source.
    func highlights(from: String, to: String) async -> [String: [SourceHighlight]] {
        var bySource: [String: [SourceHighlight]] = [:]
        var day = from
        var guardDays = 0
        while guardDays < 31 {
            for mark in (try? await storage.sourceHighlights(madeOn: day)) ?? [] {
                bySource[mark.sourceID, default: []].append(mark)
            }
            guard day != to, let next = DayPlan.dateString(day, offsetBy: 1) else { break }
            day = next
            guardDays += 1
        }
        return bySource
    }

    /// The tutor's note of what the learner marked in `sourceIDs`
    /// (`TeachBack.highlightBriefing`), in that order. Nil when nothing was.
    func highlightBriefing(_ sourceIDs: [String], marks: [String: [SourceHighlight]]) -> String? {
        TeachBack.highlightBriefing(sourceIDs.compactMap { id in
            guard let found = marks[id], !found.isEmpty else { return nil }
            let title = articlesById[id].map(recentTeachBackTitle(for:)) ?? id
            return (title, found.map { ($0.quote, $0.note) })
        })
    }

    /// The morning chat's note of the passages marked in its sources since
    /// yesterday.
    func teachBackHighlightBriefing(sourceIDs: [String], now: Date = Date()) async -> String? {
        let today = DayPlan.dateString(for: now)
        guard let yesterday = DayPlan.dateString(today, offsetBy: -1) else { return nil }
        return highlightBriefing(sourceIDs, marks: await highlights(from: yesterday, to: today))
    }

    /// A source as the recent list names it: a book's chapter says which book.
    func recentTeachBackTitle(for article: StudioArticle) -> String {
        let title = displayTitle(for: article)
        guard article.sourceType == .book, let group = article.parentGroup else { return title }
        let book = bookDisplayName(group).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !book.isEmpty, book != title else { return title }
        return "\(title)” in “\(book)"
    }

    // MARK: - The morning routine (docs/morning-routine-design.md)

    /// Every candidate for this morning's explanation, best first
    /// (`MorningPickRule.queue`), from what the app already records: what was
    /// taken in since yesterday, today's due cards, what has been explained,
    /// and on the week's first morning the nearest explained neighbour. No
    /// model call.
    func morningPickQueue(now: Date = Date()) async -> [MorningPick] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return [] }
        func eligible(_ id: String) -> Bool {
            guard let article = articlesById[id] else { return false }
            return isSourceIncludedInKnowledge(article) && !TeachBack.isFrontOrBackMatter(article.title)
        }
        var inputs = MorningPickRule.Inputs()
        // What was taken in since yesterday, the sources with passages marked
        // in them first (most marks first): marking is the learner saying it
        // mattered, and a source marked but read only briefly still counts.
        let consumed = ((try? await storage.substantiallyConsumedSourceIDs(since: yesterday, now: now)) ?? []).filter(eligible)
        let marked = await highlights(
            from: DayPlan.dateString(for: yesterday, calendar: calendar),
            to: DayPlan.dateString(for: now, calendar: calendar)
        ).mapValues(\.count).filter { eligible($0.key) }
        inputs.recent = (consumed + marked.keys.filter { !consumed.contains($0) }.sorted())
            .enumerated()
            .sorted { (marked[$0.element] ?? 0, -$0.offset) > (marked[$1.element] ?? 0, -$1.offset) }
            .map(\.element)
        inputs.explainedAt = ((try? await storage.explainedSourceDates()) ?? [:]).filter { eligible($0.key) }
        if let snapshot = try? await memoryCardReviewSnapshot(scope: .allNotebooks, includesListings: false, includesToCheck: false, now: now) {
            var overdue: [String: Int] = [:]
            for entry in snapshot.today.entries where !entry.isNew {
                for source in entry.item.sources where eligible(source.sourceID) {
                    overdue[source.sourceID] = max(overdue[source.sourceID] ?? 0, entry.daysOverdue)
                }
            }
            inputs.due = overdue.map { MorningPickRule.DueSource(sourceID: $0.key, daysOverdue: $0.value) }
        }
        let skipFloor = now.addingTimeInterval(-Double(MorningRoutine.skipDays) * 86_400)
        inputs.skipped = Set(morningSkippedAt.filter { $0.value > skipFloor }.keys)
        if MorningPickRule.isConnectionMorning(now, calendar: calendar),
           let seed = inputs.recent.first(where: { inputs.explainedAt[$0] == nil && !inputs.skipped.contains($0) }) {
            let older = Set(inputs.explainedAt.keys).subtracting(inputs.recent).subtracting(inputs.skipped)
            inputs.connectionPartner = try? await storage.nearestSource(to: seed, among: older)
        }
        return MorningPickRule.queue(inputs)
    }

    /// Whether Memory should open this morning's explanation rather than the
    /// cards: the switch is on, nothing has been explained today, the learner
    /// has not gone on to the cards today, and there is something to pick.
    func morningExplanationWaits(now: Date = Date()) async -> Bool {
        guard MemoryCardSettings.startsMorningWithExplanation(),
              morningHandedToCardsDay != MorningRoutine.dayKey(now) else { return false }
        let explained = (try? await storage.explainedSourceDates()) ?? [:]
        guard !MorningPickRule.explainedToday(explained, now: now) else { return false }
        return await !morningPickQueue(now: now).isEmpty
    }

    /// Today's morning chat, when one was started and is still in the list.
    func todaysMorningChatID(now: Date = Date()) -> String? {
        let start = Calendar.current.startOfDay(for: now)
        return reviewSessionLinks
            .filter { TeachBack.isMorningSessionID($0.id) && $0.createdAt >= start }
            .max { $0.createdAt < $1.createdAt }?
            .id
    }

    /// The Memory row (and the morning reminder): this morning's explanation
    /// while it waits, today's morning chat again if one is open, else the
    /// cards, as before.
    func openMorningOrMemory(in window: StudioWindowState) {
        Task { [weak self] in
            guard let self else { return }
            guard await morningExplanationWaits() else {
                inWindow(window) { openMemoryPane() }
                return
            }
            inWindow(window) {
                if let chatID = todaysMorningChatID() {
                    requestResumeReviewSession(chatID)
                } else {
                    requestMorningExplanation(in: window)
                }
            }
        }
    }

    /// A new morning chat on the first pick not passed over. With nothing to
    /// pick, the cards.
    func requestMorningExplanation(in window: StudioWindowState? = nil) {
        let window = window ?? chatRequestOriginWindow ?? activeWindowState
        closeNotebook(in: window)
        reviewChatPanelMode = .chat
        isChatTabActive = true
        let targetWindowID = window.id
        Task { [weak self] in
            guard let self else { return }
            guard let pick = await morningPickQueue().first else {
                inWindow(window) { openMemoryPane() }
                showToast("Nothing to explain this morning. Here are today's cards.")
                return
            }
            pendingMorningTeachBack = pick
            reviewChatAutoStartRequestID = UUID()
            reviewChatTargetWindowID = targetWindowID
        }
    }

    /// Pick something else: the chat's sources are passed over for a few
    /// days, and a new morning chat opens on the next pick.
    func requestNextMorningPick(passingOver sourceIDs: [String], in window: StudioWindowState? = nil) {
        let now = Date()
        for id in sourceIDs { morningSkippedAt[id] = now }
        requestMorningExplanation(in: window)
    }

    /// Next: today's cards. The morning is the cards' from here on today.
    func continueMorningToCards(in window: StudioWindowState? = nil) {
        morningHandedToCardsDay = MorningRoutine.dayKey(Date())
        openMemoryPane(in: window)
    }

    /// Reveal the previous-sessions list inside the open Chat panel (popover).
    func revealReviewSessionSidebar() {
        reviewSessionsRevealRequestID = UUID()
    }

}

/// What the strip's Feynman Technique hands the Chat panel: the sources, most
/// recently engaged first, and whether they are since yesterday or from the
/// past week.
struct RecentTeachBackRequest: Equatable {
    let sourceIDs: [String]
    /// The list as the opening shows it, in `sourceIDs` order.
    let lines: [TeachBack.RecentLine]
    let otherChats: [String]
    let sinceYesterday: Bool
    /// The passages marked in the listed sources, for the tutor only.
    var highlightBriefing: String? = nil
}

/// The morning routine's constants (docs/morning-routine-design.md).
enum MorningRoutine {
    /// How long a source passed over with Pick something else stays out.
    static let skipDays = 3

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
