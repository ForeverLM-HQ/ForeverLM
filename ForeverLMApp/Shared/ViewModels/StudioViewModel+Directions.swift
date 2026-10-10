import Foundation

// MARK: - Directions (docs/directions-design.md)
//
// The app's half of Directions: the list a Goal or Idea shows, the learner's
// answers to it, and Find directions, which hands the search to a Deep
// Research chat. The search itself is the chat's; nothing here asks a model
// anything.

extension StudioViewModel {

    func loadResearchDirections() async {
        do {
            let loaded = try await storage.loadResearchDirections()
            if loaded != researchDirections { researchDirections = loaded }
            hasLoadedResearchDirectionsOnce = true
        } catch {
            logger.error("Failed to load directions: \(error.localizedDescription)")
        }
    }

    /// One home's Directions in list order: pursued, proposed, set aside.
    func researchDirections(forHome homeID: String) -> [ResearchDirection] {
        researchDirections
            .filter { $0.homeID == homeID }
            .sorted(by: ResearchDirection.listOrder)
    }

    /// What a home's chip says: the Directions still worth reading, pursued
    /// and proposed, and how many of those wait for an answer.
    func researchDirectionCounts(forHome homeID: String) -> (open: Int, waiting: Int) {
        var open = 0
        var waiting = 0
        for direction in researchDirections where direction.homeID == homeID {
            switch direction.status {
            case .pursued: open += 1
            case .proposed:
                open += 1
                waiting += 1
            case .setAside: break
            }
        }
        return (open, waiting)
    }

    /// The learner's answer: Pursue, Set aside (with the reason they gave),
    /// or back to a proposal.
    func answerResearchDirection(_ directionID: String, status: DirectionStatus, reason: String? = nil) async {
        do {
            try await storage.updateResearchDirection(
                directionID,
                change: ResearchDirectionChange(status: status, verdictReason: reason)
            )
            await loadResearchDirections()
            switch status {
            case .pursued: showToast("Pursuing it")
            case .setAside: showToast("Set aside")
            case .proposed: showToast("Back to a proposal")
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to answer a direction: \(error.localizedDescription)")
            showToast("Could not save your answer")
        }
    }

    func deleteResearchDirection(_ directionID: String) async {
        do {
            try await storage.deleteResearchDirection(directionID)
            await loadResearchDirections()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to delete a direction: \(error.localizedDescription)")
            showToast("Could not delete the direction")
        }
    }

    /// The library source a piece of evidence already is, by its DOI or
    /// address; nil when the library does not have it.
    func librarySourceID(for evidence: DirectionEvidence) -> String? {
        let address = evidence.openURL?.absoluteString ?? evidence.url ?? ""
        guard !address.isEmpty || evidence.doi != nil else { return nil }
        return existingSourceID(matchingURL: address, doi: evidence.doi)
    }

    /// Add a piece of evidence to the library: the same import a cited
    /// page's Add takes, so a paper arrives with its PDF.
    @discardableResult
    func addDirectionEvidenceToLibrary(_ evidence: DirectionEvidence) async -> Bool {
        guard let url = evidence.openURL else {
            showToast("That evidence has no address to add")
            return false
        }
        return await addCitedPageToSources(url)
    }

    // MARK: Find directions

    /// Find directions for a Goal or Notebook: a Deep Research chat, sent at
    /// once, with the home's sources in context.
    func requestDirectionSearch(forGoal goal: LearningGoalRecord) {
        let kind: DirectionHomeKind = goal.isNotebook ? .notebook : .goal
        let notebookID = goal.isNotebook ? goal.id : goal.parentNotebookID
        askFirstOrStartDirectionSearch(
            DirectionSearchLaunch(homeKind: kind, homeID: goal.id, homeTitle: goal.title, notebookID: notebookID),
            sourceIDs: goal.approvedSourceIDs
        )
    }

    /// Find directions for an Idea, with the sources it is linked to in
    /// context.
    func requestDirectionSearch(forIdea idea: IdeaRecord) {
        askFirstOrStartDirectionSearch(
            DirectionSearchLaunch(homeKind: .idea, homeID: idea.id, homeTitle: idea.title, notebookID: nil),
            sourceIDs: idea.linkedIDs(.source)
        )
    }

    /// Think first (docs/fences-and-think-first-design.md): where it asks —
    /// the home's notebook's level, else the library's — the search waits for
    /// "What would you try?" in the window it was asked from; elsewhere it
    /// starts at once.
    private func askFirstOrStartDirectionSearch(_ launch: DirectionSearchLaunch, sourceIDs: [String]) {
        guard ThinkFirst.asks(.directions, notebookID: launch.notebookID) else {
            startDirectionSearch(launch, sourceIDs: sourceIDs)
            return
        }
        activeWindowState.pendingDirectionTake = DirectionTakeRequest(launch: launch, sourceIDs: sourceIDs)
    }

    /// The ask answered, or skipped (`take` nil): the learner's answer is kept
    /// in their words — a new Idea linked to a Goal or Notebook home, a dated
    /// line in the notes of an Idea home, since an Idea links to no Idea —
    /// then the search starts with it as one of its candidates.
    func answerDirectionTake(_ request: DirectionTakeRequest, take: String?) async {
        ThinkFirstTally.record(.directions, answered: take != nil)
        var launch = request.launch
        if let take {
            launch.learnerCandidate = take
            await keepDirectionTake(take, launch: launch)
        }
        startDirectionSearch(launch, sourceIDs: request.sourceIDs)
    }

    private func keepDirectionTake(_ take: String, launch: DirectionSearchLaunch) async {
        switch launch.homeKind {
        case .goal, .notebook:
            let kind: IdeaLinkKind = launch.homeKind == .notebook ? .notebook : .goal
            await createIdea(title: take, links: [IdeaLink(kind: kind, targetID: launch.homeID)])
        case .idea:
            guard let idea = ideas.first(where: { $0.id == launch.homeID }) else { return }
            let line = "What I'd try (\(Self.directionTakeDay.string(from: Date()))): \(take)"
            let existing = idea.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await updateIdea(ideaID: idea.id, notes: existing.isEmpty ? line : existing + "\n\n" + line)
        }
    }

    private static let directionTakeDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func startDirectionSearch(_ launch: DirectionSearchLaunch, sourceIDs: [String]) {
        // Only what this Mac holds goes into context; a source that has left
        // the library stays out of the chat's pool.
        let visible = sourceIDs.filter { articlesById[$0] != nil }
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        readerSelectionExplanationRequest = ReaderSelectionExplanationRequest(
            directionSearch: launch,
            sourceIDs: visible
        )
    }
}

extension StudioViewModel {

    /// Chat about one Direction: a fresh chat with the home's sources and
    /// whatever of the Direction's evidence the library holds in context, and
    /// an unsent opening line naming it, the way **Chat about it** on a Goal
    /// starts (`requestGoalChat`).
    func requestDirectionChat(_ direction: ResearchDirection) {
        var homeSources: [String] = []
        var notebookID: String?
        switch direction.homeKind {
        case .goal, .notebook:
            if let record = learningGoals.first(where: { $0.id == direction.homeID }) {
                homeSources = record.approvedSourceIDs
                notebookID = record.isNotebook ? record.id : record.parentNotebookID
            }
        case .idea:
            homeSources = ideas.first(where: { $0.id == direction.homeID })?.linkedIDs(.source) ?? []
        }
        var seen = Set<String>()
        let sources = (direction.evidence.compactMap { librarySourceID(for: $0) } + homeSources)
            .filter { articlesById[$0] != nil && seen.insert($0).inserted }
        pendingReviewChatNotebookID = notebookID.flatMap { notebook(id: $0)?.id }
        setContextSources(sources)
        pendingReviewChatDraft = Self.directionChatDraft(direction)
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// The unsent opening line for a chat about a Direction. Pure, so it can
    /// be tested.
    nonisolated static func directionChatDraft(_ direction: ResearchDirection) -> String {
        "Let's dig into this direction: “\(direction.title)”. What would it take to test it, and what is the strongest case against it?"
    }
}
