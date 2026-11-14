import Foundation

// MARK: - Notes as a graph: the Studio's entry points (docs/notes-graph-design.md)

/// Which block of a Doc to show when it opens: by its id, or, for a block
/// that has none (a block in a linked reference), by its key at a revision
/// and its text.
struct DocBlockReveal: Equatable, Sendable {
    var blockID: String?
    var key: String?
    var plainText: String?

    init(blockID: String? = nil, key: String? = nil, plainText: String? = nil) {
        self.blockID = blockID
        self.key = key
        self.plainText = plainText
    }
}

extension StudioViewModel {
    /// Today's daily note, or the day `dayKey` names, in Docs, made when it
    /// does not exist yet: the rail's Daily Notes row, ⇧⌘D, a day's link and
    /// the day stepper. A daily note is My Library's, so a team library open
    /// in the Studio gives way to My Library first, the way a team's Doc
    /// listed in My Library opens in its team (`openTeamArtifact`).
    func openDailyNote(dayKey: String? = nil, in window: StudioWindowState? = nil) async {
        let destination = window ?? activeWindowState
        let key = dayKey ?? DailyNote.dayKey(for: Date())
        guard let title = DailyNote.title(forDayKey: key) else {
            showToast("That is not a day a daily note can be kept for.")
            return
        }
        if activeTeamID != nil {
            await setActiveTeam(nil)
            guard activeTeamID == nil else { return }
        }
        do {
            let note = try await storage.ensureDailyNote(dayKey: key)
            if !artifacts.contains(where: { $0.id == note.id }) {
                artifacts = try await loadScopedArtifacts()
            }
            guard artifacts.contains(where: { $0.id == note.id }) else {
                showToast("\(title) could not be opened.")
                return
            }
            revealArtifact(note.id, in: destination)
        } catch {
            logger.error("Opening the daily note for \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            showToast("Could not open \(title): \(error.localizedDescription)")
        }
    }

    /// The plan Page for a quarter (`PlanQuarter`), made from its template
    /// when it does not exist yet: the Plan place's rows, a plan's title in a
    /// link and a plan's id. A plan is My Library's, so a team library open
    /// in the Studio gives way to My Library first, as for a daily note.
    func openPlan(_ period: PlanQuarter, in window: StudioWindowState? = nil) async {
        let destination = window ?? activeWindowState
        let title = period.title
        if activeTeamID != nil {
            await setActiveTeam(nil)
            guard activeTeamID == nil else { return }
        }
        do {
            let plan = try await storage.ensurePlan(period)
            if !artifacts.contains(where: { $0.id == plan.id }) {
                artifacts = try await loadScopedArtifacts()
            }
            guard artifacts.contains(where: { $0.id == plan.id }) else {
                showToast("\(title) could not be opened.")
                return
            }
            revealArtifact(plan.id, in: destination)
        } catch {
            logger.error("Opening the plan for \(period.key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            showToast("Could not open \(title): \(error.localizedDescription)")
        }
    }

    /// Ticks a week's deliverable in the quarter's Page, or clears its tick:
    /// the Page is read fresh and only that line's task box changes, so a
    /// line typed in the open Page meanwhile is kept. A save that loses the
    /// race to the editor reads again and tries once more.
    func setPlanDeliverable(_ deliverable: PlanDeliverable, done: Bool, weekOf monday: Date, quarter: PlanQuarter) async throws {
        let calendar = PlanQuarterWeeks.weekCalendar()
        for attempt in 0..<2 {
            let current = try await storage.artifactMarkdown(quarter.id)
            guard let markdown = PlanWeekDeliverables.setting(
                deliverable, done: done, weekOf: monday, in: current.markdown, quarter: quarter, calendar: calendar
            ) else {
                throw ArtifactError.conflict("\u{201C}\(deliverable.text)\u{201D} is no longer in \(quarter.title). Open the plan to see the week as it is now.")
            }
            do {
                _ = try await saveArtifactMarkdown(artifactID: quarter.id, markdown: markdown, expectedRevision: current.revision)
                return
            } catch ArtifactError.conflict where attempt == 0 {
                continue
            }
        }
    }

    /// The timed events of a span on the calendars ForeverLM shows, cut down
    /// to what ties them to a quarter (`PlanCalendarItem`).
    private func planCalendarItems(from start: Date, to end: Date) async throws -> [PlanCalendarItem] {
        let scope = screenRecordScope
        return try await AppleCalendarService.shared.shownEvents(from: start, to: end)
            .filter { $0.holdsTime && (scope?.allowsCalendarEvent($0) ?? true) }
            .map { event in
                PlanCalendarItem(
                    key: event.occurrenceKey,
                    title: event.title,
                    start: event.start,
                    end: event.end,
                    notes: event.notes ?? "",
                    isMeeting: event.hasOtherPeople
                )
            }
    }

    /// A quarter as the Plan place draws it: its plan's objectives, what
    /// each week is to deliver (`PlanWeekDeliverables`), and its
    /// weeks and days read off the calendars ForeverLM shows, each block
    /// tied to the objective it serves (`PlanQuarterWeeks`). A read: a plan
    /// that does not exist yet is not made. With the calendar off the weeks
    /// still list, empty, and `calendarOn` says why.
    func loadPlanOverview(_ quarter: PlanQuarter) async throws -> PlanOverview {
        var objectives: [String] = []
        var deliverables: [Date: [PlanDeliverable]] = [:]
        let weekCalendar = PlanQuarterWeeks.weekCalendar()
        let exists = try await storage.loadArtifact(quarter.id) != nil
        if exists {
            let markdown = try await storage.artifactMarkdown(quarter.id).markdown
            objectives = PlanOutline.items(under: PlanQuarter.objectivesHeading, in: markdown)
            let names = objectives.map(PlanQuarterWeeks.objectiveName)
            for monday in PlanQuarterWeeks.weekStarts(of: quarter, calendar: weekCalendar) {
                let items = PlanWeekDeliverables.deliverables(for: monday, in: markdown, quarter: quarter, objectiveNames: names, calendar: weekCalendar)
                if !items.isEmpty { deliverables[monday] = items }
            }
        }
        let calendarOn = AppleCalendarService.shared.isConnected
        var items: [PlanCalendarItem] = []
        if calendarOn, let span = PlanQuarterWeeks.span(of: quarter, calendar: weekCalendar) {
            items = try await planCalendarItems(from: span.start, to: span.end)
        }
        return PlanOverview(
            quarter: quarter,
            exists: exists,
            objectives: objectives,
            weeks: PlanQuarterWeeks.weeks(of: quarter, items: items, objectives: objectives, calendar: weekCalendar),
            deliverables: deliverables,
            calendarOn: calendarOn
        )
    }

    /// A Doc brought forward in Docs with one of its blocks shown and
    /// flashed: the doc comes forward as `revealArtifact` brings it, and the
    /// block travels on the same request to the window's canvas, which hands
    /// it to the editor once the editor holds that doc.
    func openDoc(_ docID: String, revealing reveal: DocBlockReveal?, in window: StudioWindowState? = nil) async {
        let destination = window ?? activeWindowState
        if !artifacts.contains(where: { $0.id == docID }) {
            // A day's note is My Library's: reached from a team library, the
            // library gives way to it.
            if activeTeamID != nil, let dayKey = DailyNote.dayKey(ofID: docID) {
                await openDailyNote(dayKey: dayKey, in: destination)
                if let reveal { attachBlockReveal(reveal, to: docID, in: destination) }
                return
            }
            // A plan's id names its quarter before its Page exists
            // (a foreverlm://doc/plan-… link, open_in_app): opening it makes
            // the Page, as the Plan place's row does, in My Library.
            if let period = PlanQuarter(id: docID) {
                await openPlan(period, in: destination)
                if let reveal { attachBlockReveal(reveal, to: docID, in: destination) }
                return
            }
            await loadArtifacts()
        }
        guard artifacts.contains(where: { $0.id == docID }) else {
            showToast("That page is no longer in your library")
            return
        }
        revealArtifact(docID, in: destination)
        if let reveal { attachBlockReveal(reveal, to: docID, in: destination) }
    }

    /// The page a title names (`[[Title]]`, `#tag`): the library's Doc with
    /// that title, or the daily note for a day's title, made when there is
    /// none, in the library of the Doc the title was written in. A page made
    /// here is an empty, unfiled Doc, as Roam makes one; making it is the one
    /// write opening a title does.
    func openPage(titled title: String, teamID: String?, in window: StudioWindowState? = nil) async {
        let destination = window ?? activeWindowState
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let targets = try await storage.docGraphTitleTargets(teamID: teamID)
            if let docID = targets[DocGraphSyntax.normalizedTitle(name)] {
                await openDoc(docID, revealing: nil, in: destination)
                return
            }
            // A day's title names its daily note before the note exists; a
            // daily note is My Library's, so in a team's Doc the title is an
            // ordinary one.
            if teamID == nil, let dayKey = DailyNote.dayKey(fromTitle: name) {
                await openDailyNote(dayKey: dayKey, in: destination)
                return
            }
            // A quarter's title names its plan the same way.
            if teamID == nil, let period = PlanQuarter(title: name) {
                await openPlan(period, in: destination)
                return
            }
            let snapshot = try await storage.createArtifact(
                title: name,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                teamID: teamID
            )
            artifacts = try await loadScopedArtifacts()
            revealArtifact(snapshot.artifact.id, in: destination)
            showToast("New page “\(snapshot.artifact.title)”")
        } catch {
            logger.error("Opening a page by its title failed: \(error.localizedDescription, privacy: .public)")
            showToast("Could not open “\(name)”: \(error.localizedDescription)")
        }
    }

    /// An Idea from a link: the Ideas pane with that Idea open.
    func openIdea(_ ideaID: String) async {
        let id = ideaID.trimmingCharacters(in: .whitespacesAndNewlines)
        // An Idea jotted down a moment ago, on another Mac or by an
        // assistant, may not be in the loaded list yet: storage is asked once.
        if !ideas.contains(where: { $0.id == id }) { await loadIdeas() }
        guard ideas.contains(where: { $0.id == id }) else {
            showToast("That idea is no longer in your library")
            return
        }
        let window = activeWindowState
        // Beside what is on screen, so the Doc, the chat or the source the
        // link was followed from stays where it is.
        openArtifactKindBeside(.ideas)
        // The pane opens the editor (`IdeasPane`), or answers on appearing.
        ideaRevealRequest = IdeaRevealRequest(ideaID: id, windowID: window.id)
    }
}

// MARK: - Helpers for the entry points above

extension DocBlockReveal {
    /// Whether it names a block at all: by its id, or by its text.
    var namesABlock: Bool {
        blockID?.isEmpty == false || plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

extension StudioViewModel {
    /// The block rides on the reveal request just made for the doc, to the
    /// canvas of the window the request names.
    func attachBlockReveal(_ reveal: DocBlockReveal, to docID: String, in window: StudioWindowState) {
        guard reveal.namesABlock,
              artifactRevealRequest?.artifactID == docID,
              artifactRevealRequest?.windowID == window.id else { return }
        artifactRevealRequest?.block = reveal
    }

    /// The page the editor's New page has already linked: an empty Doc with
    /// exactly the id the link names and the title it was given, in the
    /// library of the Doc the link is in, unfiled. Made already — by a second
    /// request for the same link, or arriving from another Mac — is made.
    func makeLinkedPage(id: String, title: String, teamID: String?) async throws {
        if !artifacts.contains(where: { $0.id == id }) {
            do {
                _ = try await storage.createArtifact(
                    title: title,
                    homeNotebookID: nil,
                    linkedNotebookIDs: [],
                    teamID: teamID,
                    artifactID: id
                )
            } catch {
                guard (try? await storage.artifactMarkdown(id)) != nil else { throw error }
            }
        }
        artifacts = try await loadScopedArtifacts()
    }
}
