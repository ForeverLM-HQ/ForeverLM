import AppKit
import Foundation

/// The Docs pane's half of the notes graph for one open doc
/// (docs/notes-graph-design.md, "Editor and host"): it reads the graph for the
/// editor — the block texts the doc references, which titles name pages, how
/// often each of its blocks is referenced, what points at it, and for a daily
/// note what its day held and the days before — and answers every request the
/// editor posts. Storage does the reading, off the main actor; nothing here
/// waits on it while the writer types, and an answer that arrives after the
/// pane has moved to another doc is dropped.
///
/// One per open doc, kept by `ArtifactEditor` beside its draft.
@MainActor
final class ArtifactNotesGraphHost {
    /// How many earlier days a daily note shows at a time.
    static let earlierDaysPage = 7

    let bridge = ArtifactNotesGraphBridge()

    private weak var vm: StudioViewModel?
    private weak var window: StudioWindowState?
    /// The doc being edited: the editor's own blocks are this doc's.
    private(set) var docID = ""
    /// The doc other pages point at: the doc itself, or for a member's draft
    /// of a team Doc, the team's Doc the draft will replace.
    private(set) var pageID = ""
    /// The library the doc's graph is: its team's, or My Library (nil).
    private(set) var teamID: String?
    /// The day a daily note is for; nil for every other doc.
    private(set) var dayKey: String?
    private var draft: () -> String = { "" }
    private var replaceInDraft: (_ old: String, _ new: String) -> Void = { _, _ in }
    /// Writes the draft to storage now and waits for it: the pane's own
    /// `flushDraft`, called before the writer is taken to another doc.
    private var flushDraft: () async throws -> Void = {}

    private var contextTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var earlierTask: Task<Void, Never>?
    private var dailySendTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    private var activity: [NotesGraphWire.Activity] = []
    private var earlier: [NotesGraphWire.Day] = []
    private var earlierCursor: String?
    private var hasMoreDays = false
    /// More days was pressed while the days were being read; it runs next.
    private var moreDaysPending: String?
    /// A More days answer is on its way and must reach the editor.
    private var dailySendOwesAnswer = false
    private var librarySignature: Int?
    /// The body revision the graph was last read against.
    private var bodyRevision: String?
    /// Failures already shown for this doc, so a graph that cannot be read
    /// says so once rather than on every refresh.
    private var reportedFailures: Set<String> = []
    /// Between `open` and `close`: the triggers are heard only then.
    private var isOpen = false

    var isDailyNote: Bool { dayKey != nil }

    /// The doc's body is loaded: read its graph. `librarySignature` is the
    /// library as it stands (`ArtifactNotesGraphHost.librarySignature`) and
    /// `revision` the body's, so a later change to either is heard as one.
    func open(
        docID: String,
        pageID: String,
        teamID: String?,
        vm: StudioViewModel,
        window: StudioWindowState?,
        librarySignature: Int,
        revision: String,
        draft: @escaping () -> String,
        replaceInDraft: @escaping (_ old: String, _ new: String) -> Void,
        flushDraft: @escaping () async throws -> Void
    ) {
        if docID != self.docID {
            activity = []
            earlier = []
            earlierCursor = nil
            hasMoreDays = false
            moreDaysPending = nil
            dailySendOwesAnswer = false
            reportedFailures = []
        }
        isOpen = true
        self.docID = docID
        self.pageID = pageID
        self.teamID = teamID
        self.vm = vm
        self.window = window
        self.draft = draft
        self.replaceInDraft = replaceInDraft
        self.flushDraft = flushDraft
        self.librarySignature = librarySignature
        bodyRevision = revision
        dayKey = DailyNote.dayKey(ofID: docID)
        // A daily note is My Library's; a team's Doc offers no days.
        bridge.open(docID: docID, isDailyNote: dayKey != nil, allowsDates: teamID == nil)
        bridge.onMessage = { [weak self] message, reply in self?.handle(message, reply: reply) }

        refreshContext()
        if isDailyNote {
            refreshActivity()
            reloadEarlierDays()
        } else {
            bridge.setDailyContext("null")
        }
    }

    /// The pane closed the doc. What was read stays for a reopen (`open`);
    /// what is in flight stops, and the draft's accessors, which hold the
    /// pane, are let go.
    func close() {
        for task in [contextTask, activityTask, earlierTask, dailySendTask, searchTask] {
            task?.cancel()
        }
        earlierTask = nil
        isOpen = false
        bridge.onMessage = nil
        draft = { "" }
        replaceInDraft = { _, _ in }
        flushDraft = {}
    }

    // MARK: Triggers

    /// The library's Docs or Ideas changed — another doc saved or renamed, a
    /// page made, an Idea linked: what the editor knows about the graph is
    /// read again. The pane debounces.
    func libraryChanged(signature: Int) {
        guard isOpen, signature != librarySignature else { return }
        librarySignature = signature
        refreshContext()
        if isDailyNote { reloadEarlierDays() }
    }

    /// The doc's own body was saved, or arrived from elsewhere: the counts
    /// and block texts it carries may have moved. The pane debounces.
    func bodySaved(revision: String) {
        guard isOpen, revision != bodyRevision else { return }
        bodyRevision = revision
        refreshContext()
    }

    /// The day's log changed — something read, a chat, a Doc written.
    func dayActivityChanged() {
        guard isOpen, isDailyNote else { return }
        refreshActivity()
    }

    /// What `libraryChanged` compares: the docs of the doc's own library (the
    /// open doc's own saves aside, which `bodySaved` hears), and the Ideas,
    /// each by id, name and last change.
    nonisolated static func librarySignature(artifacts: [ArtifactRecord], ideas: [IdeaRecord], openDocID: String, teamID: String?) -> Int {
        var hasher = Hasher()
        for artifact in artifacts where artifact.id != openDocID && artifact.teamID == teamID {
            hasher.combine(artifact.id)
            hasher.combine(artifact.title)
            hasher.combine(artifact.updatedAt)
        }
        if teamID == nil {
            for idea in ideas {
                hasher.combine(idea.id)
                hasher.combine(idea.title)
                hasher.combine(idea.updatedAt)
                hasher.combine(idea.links.count)
            }
        }
        return hasher.finalize()
    }

    // MARK: Reading the graph

    private func refreshContext() {
        guard let vm, !docID.isEmpty else { return }
        contextTask?.cancel()
        let storage = vm.storage
        let docID = docID
        let teamID = teamID
        let isDailyNote = isDailyNote
        let markdown = draft()
        contextTask = Task { [weak self] in
            // A long doc is read for its references off the main actor too.
            let ids = await Task.detached(priority: .userInitiated) {
                NotesGraphHostText.referencedBlockIDs(in: markdown)
            }.value
            var blocks: [String: DocGraphBlock] = [:]
            var titles: [String: String] = [:]
            var counts: [String: Int] = [:]
            var failure: Error?
            do {
                if !ids.isEmpty { blocks = try await storage.docGraphBlocks(ids, teamID: teamID) }
            } catch { failure = error }
            do { titles = try await storage.docGraphTitleTargets(teamID: teamID) } catch { failure = failure ?? error }
            do { counts = try await storage.docGraphReferenceCounts(inDoc: docID) } catch { failure = failure ?? error }
            guard !Task.isCancelled, let self, self.docID == docID else { return }
            let docTitles = self.docTitles()
            let context = NotesGraphWire.GraphContext(
                docID: docID,
                isDailyNote: isDailyNote,
                allowsDates: teamID == nil,
                blocks: blocks.mapValues { NotesGraphWire.Block($0, docTitle: docTitles[$0.docID] ?? "") },
                titles: titles.mapValues { NotesGraphWire.TitleTarget(id: $0) },
                refCounts: counts
            )
            let json = await NotesGraphWire.jsonOffMain(context)
            guard !Task.isCancelled, self.docID == docID else { return }
            self.bridge.setContext(json)
            if let failure { self.report(failure) }
        }
    }

    /// What the day held: its log and the passages highlighted that day.
    private func refreshActivity() {
        guard let vm, let dayKey else { return }
        activityTask?.cancel()
        let storage = vm.storage
        let docID = docID
        activityTask = Task { [weak self] in
            var spans: [DayActivity] = []
            var highlights: [SourceHighlight] = []
            var failure: Error?
            do {
                if let stored = try await storage.loadDayPlan(dayKey) {
                    // Screen record mode (admin only) films the take's own log.
                    let scoped = await storage.screenRecordScope().map { $0.scoped(stored) } ?? stored
                    spans = scoped.activities
                }
            } catch { failure = error }
            do { highlights = try await storage.sourceHighlights(madeOn: dayKey) } catch { failure = failure ?? error }
            guard !Task.isCancelled, let self, self.docID == docID, let vm = self.vm else { return }
            self.activity = NotesGraphDailyActivity.items(
                activities: spans,
                highlights: highlights,
                dayKey: dayKey,
                excludingDocID: docID,
                title: { kind, targetID, logged in self.currentTitle(kind: kind, targetID: targetID, logged: logged) },
                sourceTitle: { sourceID in vm.articlesById[sourceID].map { vm.displayTitle(for: $0) } }
            )
            self.sendDailyContext()
            if let failure { self.report(failure) }
        }
    }

    /// The days before this one, from the top, as many as are shown now.
    private func reloadEarlierDays() {
        guard let vm, let dayKey else { return }
        earlierTask?.cancel()
        let storage = vm.storage
        let docID = docID
        let wanted = max(Self.earlierDaysPage, earlier.count)
        earlierTask = Task { [weak self] in
            do {
                let page = try await NotesGraphEarlierDays.collect(
                    before: dayKey,
                    wanted: wanted,
                    notes: { try await storage.dailyNotes(before: $0, limit: $1) },
                    markdown: { try await storage.artifactMarkdown($0).markdown }
                )
                guard !Task.isCancelled, let self, self.docID == docID else { return }
                self.earlier = page.days
                self.earlierCursor = page.cursor
                self.hasMoreDays = page.hasMore
                self.earlierTask = nil
                self.sendDailyContext()
                self.sendBlocksReferenced(by: page.days)
                self.runPendingMoreDays()
            } catch {
                guard !Task.isCancelled, let self, self.docID == docID else { return }
                self.earlierTask = nil
                self.report(error)
                self.runPendingMoreDays()
            }
        }
    }

    private func runPendingMoreDays() {
        guard let before = moreDaysPending else { return }
        moreDaysPending = nil
        if hasMoreDays { loadMoreDays(before: before) } else { sendDailyContext(answering: true) }
    }

    /// More days: the next page of written days, after those shown.
    private func loadMoreDays(before: String) {
        guard let vm, isDailyNote else { return }
        guard earlierTask == nil else {
            moreDaysPending = before
            return
        }
        let storage = vm.storage
        let docID = docID
        let cursor = earlierCursor ?? before
        earlierTask = Task { [weak self] in
            do {
                let page = try await NotesGraphEarlierDays.collect(
                    before: cursor,
                    wanted: Self.earlierDaysPage,
                    notes: { try await storage.dailyNotes(before: $0, limit: $1) },
                    markdown: { try await storage.artifactMarkdown($0).markdown }
                )
                guard !Task.isCancelled, let self, self.docID == docID else { return }
                let shown = Set(self.earlier.map(\.docID))
                self.earlier += page.days.filter { !shown.contains($0.docID) }
                self.earlierCursor = page.cursor ?? self.earlierCursor
                self.hasMoreDays = page.hasMore
                self.earlierTask = nil
                self.sendDailyContext(answering: true)
                self.sendBlocksReferenced(by: page.days)
            } catch {
                guard !Task.isCancelled, let self, self.docID == docID else { return }
                self.earlierTask = nil
                // The editor stops waiting on More days; the reason is said.
                self.sendDailyContext(answering: true)
                self.report(error)
            }
        }
    }

    /// `answering` is the answer to More days: said even when it is what
    /// the editor already holds, since the editor waits on it.
    private func sendDailyContext(answering: Bool = false) {
        guard let dayKey else {
            bridge.setDailyContext("null")
            return
        }
        let context = NotesGraphWire.DailyContext(
            dayKey: dayKey,
            isToday: DailyNoteDays.isToday(dayKey),
            activity: activity,
            earlier: earlier,
            hasMore: hasMoreDays
        )
        let docID = docID
        dailySendOwesAnswer = dailySendOwesAnswer || answering
        dailySendTask?.cancel()
        dailySendTask = Task { [weak self] in
            let json = await NotesGraphWire.jsonOffMain(context)
            guard !Task.isCancelled, let self, self.docID == docID else { return }
            self.bridge.setDailyContext(json, force: self.dailySendOwesAnswer)
            self.dailySendOwesAnswer = false
        }
    }

    /// The earlier days are drawn by the editor, references and all; the
    /// blocks they reference go into its context with them.
    private func sendBlocksReferenced(by days: [NotesGraphWire.Day]) {
        guard let vm else { return }
        var seen = Set<String>()
        let ids = days.flatMap { NotesGraphHostText.referencedBlockIDs(in: $0.markdown) }.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        let storage = vm.storage
        let logger = vm.logger
        let docID = docID
        Task { [weak self] in
            let blocks: [String: DocGraphBlock]
            do {
                blocks = try await storage.docGraphBlocks(ids, teamID: nil)
            } catch {
                logger.error("Reading the blocks the earlier days reference failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !blocks.isEmpty, let self, self.docID == docID else { return }
            let titles = self.docTitles()
            let json = await NotesGraphWire.jsonOffMain(blocks.mapValues { NotesGraphWire.Block($0, docTitle: titles[$0.docID] ?? "") })
            guard self.docID == docID else { return }
            self.bridge.mergeBlocks(json)
        }
    }

    // MARK: Answering the editor

    /// A page the editor made (`/page`) comes forward in this window the way
    /// following its link does. The doc holding the link is saved first, with
    /// the text the editor holds now, so the link is not lost when this doc
    /// closes behind the new one; if it cannot be saved the page stays made
    /// and the writer stays here.
    private func openMadePage(_ pageID: String, title: String, from requestingDocID: String) async {
        guard let vm, isOpen, docID == requestingDocID else { return }
        do {
            try await bridge.syncMarkdownFromPage()
            try await flushDraft()
        } catch {
            vm.showToast("“\(title)” was made but not opened: this page could not be saved first. \(error.localizedDescription)")
            return
        }
        // The pane may have moved on while the draft was written.
        guard isOpen, docID == requestingDocID else { return }
        await vm.openDoc(pageID, revealing: nil, in: window)
    }

    private func handle(_ message: ArtifactNotesGraphMessage, reply: ArtifactNotesGraphReply) {
        guard let vm else { return }
        let storage = vm.storage
        let teamID = teamID
        let window = window
        switch message {
        case .blocksRequested(let ids):
            Task { [weak self] in
                do {
                    let blocks = try await storage.docGraphBlocks(ids, teamID: teamID)
                    guard let self else { return }
                    let titles = self.docTitles()
                    reply.setBlocks(await NotesGraphWire.jsonOffMain(blocks.mapValues { NotesGraphWire.Block($0, docTitle: titles[$0.docID] ?? "") }))
                } catch {
                    self?.report(error)
                }
            }

        case .blockSearchRequested(let requestID, let query):
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                do {
                    let hits = try await storage.docGraphSearchBlocks(query, teamID: teamID, limit: 12)
                    guard !Task.isCancelled else { return }
                    let json = await NotesGraphWire.jsonOffMain(hits.map(NotesGraphWire.Hit.init))
                    guard !Task.isCancelled else { return }
                    reply.setBlockSearchResults(requestID: requestID, hitsJSON: json)
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    // The picker stops waiting, and the reason is said.
                    reply.setBlockSearchResults(requestID: requestID, hitsJSON: "[]")
                    self?.report(error)
                }
            }

        case .blockIDAssigned(let targetDocID, let key, let revision, let plainText, let proposedID):
            // A block of the doc being written is marked by the editor itself.
            guard targetDocID != docID else { return }
            Task { [weak self] in
                do {
                    let assigned = try await storage.docGraphAssignBlockID(
                        docID: targetDocID,
                        key: key,
                        revision: revision,
                        expectedPlainText: plainText,
                        proposedID: proposedID
                    )
                    guard let self else { return }
                    // The block had an id of its own already: the reference
                    // the editor wrote takes it, an ordinary edit of this doc.
                    if assigned != proposedID {
                        self.replaceInDraft(DocGraphSyntax.blockReference(proposedID), DocGraphSyntax.blockReference(assigned))
                    }
                    let blocks = try await storage.docGraphBlocks([assigned], teamID: teamID)
                    let titles = self.docTitles()
                    reply.setBlocks(await NotesGraphWire.jsonOffMain(blocks.mapValues { NotesGraphWire.Block($0, docTitle: titles[$0.docID] ?? "") }))
                    // The other doc changed on disk: every pane showing it,
                    // and this doc's graph, hear it through the library.
                    let reloaded = await vm.loggedRead("the Docs") { try await vm.loadScopedArtifacts() }
                    if let reloaded { vm.artifacts = reloaded }
                } catch {
                    vm.showToast(error.localizedDescription)
                }
            }

        case .pageCreationRequested(let newDocID, let title, let dayKey, let openAfter, let nested):
            // The doc the request came from: a writer who has moved on while
            // the page was being made is not taken anywhere.
            let requestingDocID = docID
            // A subpage is nested under the page the Page row was used in: the
            // learner's own page, never a team's.
            let parentPageID: String? = nested && dayKey == nil && teamID == nil && !isDailyNote ? requestingDocID : nil
            Task { [weak self] in
                do {
                    if let day = dayKey ?? DailyNote.dayKey(ofID: newDocID) {
                        _ = try await storage.ensureDailyNote(dayKey: day)
                        vm.artifacts = try await vm.loadScopedArtifacts()
                    } else {
                        // The editor names a new page by a fresh UUID; nothing
                        // else becomes a folder name in the library.
                        guard UUID(uuidString: newDocID) != nil else {
                            vm.showToast("“\(title)” could not be made: the link names no new page.")
                            return
                        }
                        try await vm.makeLinkedPage(id: newDocID, title: title, teamID: teamID)
                        if let parentPageID { vm.nestNewPage(newDocID, under: parentPageID) }
                    }
                    self?.refreshContext()
                } catch {
                    vm.showToast("Could not make “\(title)”: \(error.localizedDescription)")
                    return
                }
                if openAfter { await self?.openMadePage(newDocID, title: title, from: requestingDocID) }
            }

        case .openTitleRequested(let title):
            Task { await vm.openPage(titled: title, teamID: teamID, in: window) }

        case .openBlockRequested(let blockID):
            Task {
                do {
                    guard let block = try await storage.docGraphBlocks([blockID], teamID: teamID)[blockID] else {
                        vm.showToast(DocGraphError.blockNotFound(blockID).localizedDescription)
                        return
                    }
                    await vm.openDoc(
                        block.docID,
                        revealing: DocBlockReveal(blockID: blockID, key: block.key, plainText: block.plainText),
                        in: window
                    )
                } catch {
                    vm.showToast(error.localizedDescription)
                }
            }

        case .openReferenceRequested(let kind, let id, let blockID, let plainText):
            Task {
                if kind == "idea" {
                    await vm.openIdea(id)
                } else {
                    await vm.openDoc(id, revealing: DocBlockReveal(blockID: blockID, plainText: plainText), in: window)
                }
            }

        case .copyToPasteboardRequested(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            vm.showToast(NotesGraphHostText.copyConfirmation(for: text))

        case .makeIdeaRequested(let text, _):
            let title = NotesGraphHostText.ideaTitle(from: text)
            guard !title.isEmpty else { return }
            let pageID = pageID
            Task {
                // `createIdea` says so itself when the Idea could not be kept.
                if await vm.createIdea(title: title, links: [IdeaLink(kind: .artifact, targetID: pageID)]) != nil {
                    vm.showToast("Idea made")
                }
            }

        case .dailyNoteRequested(let dayKey):
            Task { await vm.openDailyNote(dayKey: dayKey, in: window) }

        case .dailyNotesMoreRequested(let before):
            loadMoreDays(before: before)

        case .blockReferencesRequested(let blockID):
            Task { [weak self] in
                do {
                    let groups = try await storage.docGraphLinkedReferences(to: .block(blockID), teamID: teamID)
                    reply.setBlockReferencesFor(blockID: blockID, groupsJSON: await NotesGraphWire.jsonOffMain(groups.map(NotesGraphWire.Group.init)))
                } catch {
                    reply.setBlockReferencesFor(blockID: blockID, groupsJSON: "[]")
                    self?.report(error)
                }
            }

        case .openSourceRequested(let link):
            Task {
                // A highlight opens its source at the passage, flashed.
                var passage: String?
                if let highlightID = link.highlightID {
                    let highlights = await vm.loggedRead("the source's highlights") {
                        try await storage.sourceHighlights(sourceID: link.sourceID)
                    }
                    passage = highlights?.first { $0.id == highlightID }?.quote
                }
                await vm.openLinkedSourceInReader(link.sourceID, passage: passage, beside: .notepad)
            }
        }
    }

    // MARK: Names

    private func docTitles() -> [String: String] {
        Dictionary((vm?.artifacts ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// A logged thing's name as it is called now, else as it was logged.
    private func currentTitle(kind: DayActivityKind, targetID: String, logged: String) -> String {
        guard let vm else { return logged }
        switch kind {
        case .reading, .listening, .watching:
            return vm.articlesById[targetID].map { vm.displayTitle(for: $0) } ?? logged
        case .chat:
            return vm.reviewSessionLinks.first { $0.id == targetID }?.title ?? logged
        case .doc:
            return vm.artifacts.first { $0.id == targetID }?.title ?? logged
        case .offTrack:
            return logged
        }
    }

    /// A failure to read the graph, said once per doc.
    private func report(_ error: Error) {
        guard !(error is CancellationError), let vm else { return }
        let message = error.localizedDescription
        vm.logger.error("Notes graph for doc \(self.docID, privacy: .public): \(message, privacy: .public)")
        guard reportedFailures.insert(message).inserted else { return }
        vm.showToast(message)
    }
}
