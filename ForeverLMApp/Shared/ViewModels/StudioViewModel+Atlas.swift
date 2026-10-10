import Foundation

enum AtlasRequestError: LocalizedError, Equatable {
    case nothingToLayOut
    case notFound

    var errorDescription: String? {
        switch self {
        case .nothingToLayOut: return "Name a topic, or pick cards or a notebook, to lay out an Atlas."
        case .notFound: return "That Atlas is no longer in ForeverLM."
        }
    }
}

/// The Atlas's routes in and out of the rest of the app
/// (docs/atlas-design.md): opening and building one, deepening a concept,
/// Learn, Ask in Chat and Lay Out on Canvas.
extension StudioViewModel {

    // MARK: Opening

    /// View ▸ Atlas: the pane in this window, showing what it showed last.
    func openAtlasPane(in windowState: StudioWindowState? = nil) {
        activateCenterTab(.atlas, in: windowState ?? activeWindowState)
        Task { await refreshAtlasListings() }
    }

    /// The Atlas on screen in the active window, beside the Canvas or the
    /// chat it was asked for from, which stays where it is; else beside
    /// whatever shows. A window holding a notebook leaves it, as for the
    /// Canvas.
    func revealAtlasPane() {
        let window = activeWindowState
        let visible = visibleCenterTabs(in: window)
        guard !visible.contains(.atlas) else { return }
        if window.notebook == nil,
           let companion = [StudioCenterTab.knowledgeMap, .chat].first(where: { visible.contains($0) }) {
            revealCenterTab(.atlas, beside: companion, in: window)
        } else {
            openCenterTabBeside(.atlas)
        }
    }

    /// Whether any window shows the Atlas.
    var atlasIsOnScreen: Bool {
        StudioWindowRegistry.shared.states.contains { state in
            state.centerTabGroups.groups.contains { $0.activeTab == .atlas }
        }
    }

    /// `openAtlas(topic:itemRefs:notebookID:)`: the pane beside what is on
    /// screen, then the Atlas already made for this request, else a new one.
    /// What fails is said in the pane and in a toast.
    func presentAtlas(topic: String?, itemRefs: [String], notebookID: String?) {
        revealAtlasPane()
        Task {
            do {
                _ = try await self.makeAtlas(topic: topic, itemRefs: itemRefs, notebookID: notebookID)
            } catch is CancellationError {
                // Stopped from the pane.
            } catch {
                self.showToast("Could not lay out the Atlas: \(error.localizedDescription)")
            }
        }
    }

    /// The Atlas for this request, shown in the Atlas pane: the one already
    /// made for the same topic and scope, opened as it is (opening writes
    /// nothing), else built now. `rebuild` writes a matching one again.
    @discardableResult
    func makeAtlas(topic: String?, itemRefs: [String], notebookID: String?, rebuild: Bool = false) async throws -> (atlas: Atlas, existing: Bool) {
        guard let request = atlasRequest(topic: topic, itemRefs: itemRefs, notebookID: notebookID) else {
            throw AtlasRequestError.nothingToLayOut
        }
        let rows = try await storage.loadAtlasRows()
        let listings = rows.map(AtlasListing.init(row:))
        atlas.setListings(listings)
        var previous: Atlas?
        if let match = listings.first(where: { $0.answers(topic: topic, scope: request.scope) }),
           let row = rows.first(where: { $0.id == match.id }) {
            let existing = try Atlas(row: row)
            if !rebuild {
                atlas.show(existing)
                await refreshAtlasMemory()
                return (existing, true)
            }
            previous = existing
        }
        let task = startAtlasBuild(request, replacing: previous)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return (try result.get(), false)
    }

    /// The pane's empty state and the title field: an Atlas of what the
    /// learner typed, over the whole library.
    func buildAtlas(topic: String) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presentAtlas(topic: trimmed, itemRefs: [], notebookID: nil)
    }

    /// ⋯ ▸ Rebuild: the Atlas on screen written again over the same scope,
    /// under the same id. It replaces the old one once it is written.
    func rebuildAtlas() {
        guard let current = atlas.current else { return }
        let request = AtlasBuilder.Request(
            topic: current.topic,
            topicIsLearners: true,
            scope: current.scope,
            scopeSourceIDs: [],
            learnerTerms: atlasLearnerTerms(itemRefs: current.scope.itemRefs, notebookID: current.scope.notebookID)
        )
        Task {
            var full = request
            full.scopeSourceIDs = await AtlasBuilder.scopeSourceIDs(for: current.scope, studio: self)
            let result = await self.startAtlasBuild(full, replacing: current).value
            if case .failure(let error) = result, !(error is CancellationError) {
                self.showToast("Could not rebuild the Atlas: \(error.localizedDescription)")
            }
        }
    }

    /// Builds in the background of the pane, which shows "✦ Laying out …"
    /// with Stop; saved whole when written, nothing saved when stopped or
    /// failed. A newer build stops an older one.
    @discardableResult
    func startAtlasBuild(_ request: AtlasBuilder.Request, replacing previous: Atlas? = nil) -> Task<Result<Atlas, Error>, Never> {
        let model = atlas
        model.buildTask?.cancel()
        // A deepening written against the Atlas being replaced must not land
        // on the new one, whose concept ids name other concepts.
        model.deepenTask?.cancel()
        let cards = request.scope.itemRefs.count
        let shownTopic = request.topicIsLearners ? request.topic : (cards == 1 ? "this card" : "these \(cards) cards")
        let generation = model.beginBuilding(topic: shownTopic)
        let task = Task { @MainActor [weak self] () -> Result<Atlas, Error> in
            guard let self else { return .failure(CancellationError()) }
            do {
                var request = request
                if request.scopeSourceIDs.isEmpty, !request.scope.isWholeLibrary {
                    request.scopeSourceIDs = await AtlasBuilder.scopeSourceIDs(for: request.scope, studio: self)
                }
                let built = try await AtlasBuilder.build(request, replacing: previous, studio: self) { stage in
                    model.setStage(stage, generation: generation)
                }
                try Task.checkCancellation()
                try await self.storage.saveAtlasRow(try built.row())
                model.finishBuilding(generation: generation, error: nil)
                model.show(built, asNew: previous != nil)
                await self.refreshAtlasListings()
                await self.refreshAtlasMemory()
                return .success(built)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    model.finishBuilding(generation: generation, error: nil)
                    return .failure(CancellationError())
                }
                self.logger.error("Atlas build failed: \(error.localizedDescription)")
                model.finishBuilding(generation: generation, error: error.localizedDescription)
                return .failure(error)
            }
        }
        model.buildTask = task
        return task
    }

    /// What to build for a request: the topic (the learner's, else a region
    /// the cards share, an Idea's sentence, the notebook's name, else card
    /// titles for the model to name), the scope and the learner's own terms.
    /// Nil when there is nothing to lay out.
    func atlasRequest(topic: String?, itemRefs: [String], notebookID: String?) -> AtlasBuilder.Request? {
        let scope = AtlasScope(itemRefs: itemRefs, notebookID: notebookID)
        let refs = scope.itemRefs.compactMap(KnowledgeMap.ItemRef.init)
        let ideaSentences = refs.filter { $0.kind == .idea }.compactMap { ref in
            ideas.first { $0.id == ref.id }?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let regionNames = atlasRegionNames(scope.itemRefs)
        let notebookName = notebookID.flatMap { notebook(id: $0) }.map { NotebookTitle($0.title).text }
        let terms = atlasLearnerTerms(itemRefs: scope.itemRefs, notebookID: notebookID)
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            return .init(topic: topic, topicIsLearners: true, scope: scope, scopeSourceIDs: [], learnerTerms: terms)
        }
        if let region = regionNames.first {
            return .init(topic: region, topicIsLearners: true, scope: scope, scopeSourceIDs: [], learnerTerms: terms)
        }
        if let sentence = ideaSentences.first {
            return .init(topic: sentence, topicIsLearners: true, scope: scope, scopeSourceIDs: [], learnerTerms: terms)
        }
        if let notebookName, !notebookName.isEmpty {
            return .init(topic: notebookName, topicIsLearners: true, scope: scope, scopeSourceIDs: [], learnerTerms: terms)
        }
        let titles = refs.compactMap { ref -> String? in
            switch ref.kind {
            case .source: return articlesById[canonicalSourceID(ref.id)]?.title
            case .doc: return artifacts.first { $0.id == ref.id }?.title
            case .idea: return nil
            case .clip: return knowledgeMap.clips[ref.id].flatMap { articlesById[canonicalSourceID($0.sourceID)]?.title }
            case .page: return ref.pageParts.flatMap { articlesById[canonicalSourceID($0.sourceID)]?.title }
            // A shortcut to a canvas, a chat and a picture are not sources:
            // they name no paper for the search to read.
            case .canvas, .chat, .picture: return nil
            }
        }
        guard !titles.isEmpty else { return nil }
        // The search reads the titles; the model names the topic.
        return .init(topic: titles.prefix(4).joined(separator: "; "), topicIsLearners: false, scope: scope, scopeSourceIDs: [], learnerTerms: terms)
    }

    /// The names of the regions the placed cards sit in, the most shared first.
    private func atlasRegionNames(_ itemRefs: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for ref in itemRefs {
            guard let regionID = knowledgeMap.regionID(containing: ref) else { continue }
            let name = (knowledgeMap.notebook(ofRegion: regionID)?.title ?? knowledgeMap.layout.regions[regionID]?.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    /// The learner's own words around a scope: its Idea sentences, the
    /// regions its cards sit in, and the notebook's name.
    func atlasLearnerTerms(itemRefs: [String], notebookID: String?) -> [String] {
        var terms: [String] = []
        for raw in itemRefs {
            guard let ref = KnowledgeMap.ItemRef(raw), ref.kind == .idea,
                  let idea = ideas.first(where: { $0.id == ref.id }) else { continue }
            let sentence = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { terms.append(sentence) }
        }
        terms += atlasRegionNames(itemRefs)
        if let notebookID, let notebook = notebook(id: notebookID) {
            let name = NotebookTitle(notebook.title).text
            if !name.isEmpty { terms.append(name) }
        }
        var seen: Set<String> = []
        return terms.filter { seen.insert($0.lowercased()).inserted }.prefix(12).map { $0 }
    }

    // MARK: Stored Atlases

    /// The title's menu: every Atlas made, the latest first.
    func refreshAtlasListings() async {
        do {
            let rows = try await storage.loadAtlasRows()
            atlas.setListings(rows.map(AtlasListing.init(row:)))
        } catch {
            logger.error("Could not read the Atlases: \(error.localizedDescription)")
            showToast("Could not read your Atlases: \(error.localizedDescription)")
        }
    }

    /// Opens a stored Atlas as it is: opening writes nothing.
    func openStoredAtlas(id: String) async {
        do {
            guard let row = try await storage.loadAtlasRow(id: id) else { throw AtlasRequestError.notFound }
            atlas.show(try Atlas(row: row))
            await refreshAtlasMemory()
        } catch {
            showToast("Could not open the Atlas: \(error.localizedDescription)")
        }
    }

    /// ⋯ ▸ Delete: the Atlas goes for good. It is ForeverLM's writing, made
    /// again with the same topic; nothing of the learner's goes with it.
    func deleteAtlas(id: String) async throws {
        try await storage.deleteAtlasRow(id: id)
        if atlas.current?.id == id { atlas.clear() }
        await refreshAtlasListings()
    }

    // MARK: Deepening

    /// Writes the focused concept in depth when the level asks for more than
    /// it holds, once: called as the focus or the level changes. Moving on
    /// stops it (`AtlasModel.focus`).
    func deepenAtlasFocusIfNeeded() {
        let model = atlas
        guard model.building == nil,
              let current = model.current,
              let id = model.focusID,
              let concept = current.concept(id),
              concept.needsDeepening(at: model.focusLevel),
              model.deepeningID != id,
              model.deepenError?.conceptID != id else { return }
        model.deepenTask?.cancel()
        model.beginDeepening(id)
        let atlasID = current.id
        model.deepenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.deepenAtlasConcept(atlasID: atlasID, conceptID: id)
                model.endDeepening(id, error: nil)
            } catch {
                let stopped = error is CancellationError || Task.isCancelled
                model.endDeepening(id, error: stopped ? nil : error.localizedDescription)
            }
        }
    }

    /// One concept of a stored Atlas written in depth and saved; the pane
    /// shows it when that Atlas is on screen. Also `get_atlas` with deepen.
    @discardableResult
    func deepenAtlasConcept(atlasID: String, conceptID: String) async throws -> Atlas {
        let base: Atlas
        if let current = atlas.current, current.id == atlasID {
            base = current
        } else {
            guard let row = try await storage.loadAtlasRow(id: atlasID) else { throw AtlasRequestError.notFound }
            base = try Atlas(row: row)
        }
        guard base.concept(conceptID) != nil else { throw AtlasBuildError.unknownConcept }
        let deepened = try await AtlasBuilder.deepen(base, conceptID: conceptID, studio: self)
        try Task.checkCancellation()
        // Onto the newest copy: another concept may have been deepened while
        // this one was written.
        var latest = base
        if let current = atlas.current, current.id == atlasID {
            latest = current
        } else if let row = try await storage.loadAtlasRow(id: atlasID) {
            latest = try Atlas(row: row)
        }
        // A Rebuild keeps the Atlas's id and day, so the concept itself says
        // whether it is still the one that was written in depth.
        guard let before = base.concept(conceptID), let after = latest.concept(conceptID),
              after.name == before.name, after.line == before.line else {
            // Rebuilt while this was written: the concept is another one now.
            throw CancellationError()
        }
        let merged = latest.adopting(conceptID, from: deepened, at: Date())
        try await storage.saveAtlasRow(try merged.row())
        atlas.replace(merged)
        await refreshAtlasMemory()
        return merged
    }

    // MARK: Memory

    /// How the kept cards on the Atlas's sources stand, for its dots.
    func refreshAtlasMemory() async {
        guard let current = atlas.current else { return }
        let marks = await memoryMarks(forSourceIDs: current.evidenceSourceIDs)
        guard atlas.current?.id == current.id else { return }
        atlas.setMemoryMarks(marks)
    }

    /// Learn: cards drafted from the concept and its first terms, each
    /// anchored to a quote from the concept's sources, into To Check.
    func learnAtlasConcept(_ conceptID: String) async {
        guard let current = atlas.current, let concept = current.concept(conceptID) else { return }
        let anchors = current.learnAnchors(for: conceptID)
        guard !anchors.isEmpty else {
            showToast("\(concept.name) has no passage in your library to make a card from")
            return
        }
        atlas.learningID = conceptID
        defer { atlas.learningID = nil }
        do {
            let outcome = try await SituatedCardDrafter.draft(anchors, studio: self)
            if outcome.drafted > 0 {
                showToast("Drafted \(outcome.drafted) card\(outcome.drafted == 1 ? "" : "s") on \(concept.name) into To Check")
            } else if outcome.notGrounded > 0 {
                showToast("No card on \(concept.name) could quote its sources, so none was drafted")
            } else {
                showToast("No card was drafted on \(concept.name)")
            }
            await refreshAtlasMemory()
        } catch {
            showToast("Could not draft cards on \(concept.name): \(error.localizedDescription)")
        }
    }

    // MARK: Out to the chat and the Canvas

    /// Ask in Chat: a fresh chat beside the Atlas with the concept's sources
    /// attached and "Explain <concept>" typed, unsent, as the Canvas's Ask in
    /// Chat opens one over what is circled.
    func requestChatAboutAtlasConcept(_ conceptID: String, in windowState: StudioWindowState) {
        guard let current = atlas.current, let concept = current.concept(conceptID) else { return }
        let sourceIDs = current.groundingSourceIDs(of: conceptID)
        let inTopic = conceptID == current.rootID || concept.name.caseInsensitiveCompare(current.topic) == .orderedSame
            ? ""
            : " in \(current.topic)"
        setContextSources(sourceIDs)
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = "Explain \(concept.name)\(inTopic) "
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        revealCenterTab(.chat, beside: .atlas, in: windowState)
        if !sourceIDs.isEmpty {
            showToast(Self.addedToChatMessage(sourceIDs.count == 1 ? "Its source" : "Its \(sourceIDs.count) sources", elsewhere: chatRequestElsewhereNotice))
        }
    }

    /// Lay Out on Canvas: the Atlas (or one branch) as a concepts lens over
    /// the Canvas, opened beside the Atlas, through the path `apply_map_lens`
    /// takes. Nothing is placed until the learner presses Keep there.
    func layOutAtlasOnCanvas(branch conceptID: String?, in windowState: StudioWindowState) async {
        guard let current = atlas.current else { return }
        guard let request = current.canvasLensRequest(branch: conceptID) else {
            showToast("No concept here has a source in your library yet, so there is nothing to place on the Canvas")
            return
        }
        if knowledgeMap.content.nodes.isEmpty {
            await refreshKnowledgeMapContent()
        }
        if !visibleCenterTabs(in: windowState).contains(.knowledgeMap) {
            revealCenterTab(.knowledgeMap, beside: .atlas, in: windowState)
        }
        do {
            let lens = try knowledgeMap.apply(request)
            showToast("\(lens.frames.count) concepts and \(lens.positions.count) sources on the Canvas: Keep makes them yours")
        } catch {
            showToast("Could not lay the Atlas out on the Canvas: \(error.localizedDescription)")
        }
    }

    /// A passage's Open: the Reader beside the Atlas, at that passage.
    func openAtlasPassage(_ passage: AtlasPassage) async {
        await openLinkedSourceInReader(passage.sourceID, passage: passage.text, beside: .atlas)
    }
}
