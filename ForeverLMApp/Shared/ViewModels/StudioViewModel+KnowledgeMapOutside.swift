import Foundation

// MARK: - Cards from outside the Canvas
//
// What brings things onto the Canvas from outside it: files dropped from the
// Finder, pictures, addresses and words pasted, chats dragged on, an answer
// from the chat pane, and Add to Canvas ▸ from every list; and the two ways
// between canvases, Move to Canvas ▸ and "On canvases"
// (docs/knowledge-map-design.md, "Dropping from the rest of the app"; the
// pure half is `KnowledgeMapOutside`). Nothing is placed before what it names
// is in the library, and a failure says why in a toast.

extension StudioViewModel {

    // MARK: The canvases a card can be added to

    /// The canvases an Add to Canvas ▸ menu lists: the learner's own, not in
    /// Trash, the open one first, then the rest by last activity. The open
    /// canvas is listed before its row exists (the first canvas, until
    /// something is written to it).
    var canvasesToAddTo: [KnowledgeMapCanvas] {
        guard listsCanvases else { return [] }
        let openID = knowledgeMap.mapID
        var live = listedCanvases.filter { !$0.isTrashed }
        if !live.contains(where: { $0.id == openID }), !(canvases.canvas(openID)?.isTrashed ?? false) {
            live.append(KnowledgeMapCanvas(id: openID, name: KnowledgeMap.unnamedCanvasName, createdAt: .distantPast, updatedAt: .distantPast))
        }
        return live.sorted { lhs, rhs in
            if (lhs.id == openID) != (rhs.id == openID) { return lhs.id == openID }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// A canvas's name as a toast says it.
    private func canvasNameForToast(_ canvasID: String) -> String {
        if let canvas = canvases.canvas(canvasID) { return canvas.name }
        return canvasID == knowledgeMap.mapID ? KnowledgeMap.unnamedCanvasName : "the canvas"
    }

    /// The canvases (not in Trash) that hold the card `ref` names, the one
    /// last active first. The rows are read once per change to a canvas, not
    /// once per call, so a list of rows can ask for each of its cards.
    func canvasesHolding(ref: String) -> [KnowledgeMapCanvas] {
        guard listsCanvases else { return [] }
        let live = canvases.inUse
        let ids = KnowledgeMapPlacementIndex.shared.canvasIDs(holding: canonicalKnowledgeMapRef(ref), among: live)
        return live
            .filter { ids.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id < rhs.id
            }
    }

    // MARK: Add to Canvas ▸

    /// A card's ref as a canvas keeps it: a source by the id its Sources row
    /// has (a team's copy by the learner's own), every other ref as given.
    func canonicalKnowledgeMapRef(_ ref: String) -> String {
        let prefix = "source:"
        guard ref.hasPrefix(prefix) else { return ref }
        let token = String(ref.dropFirst(prefix.count))
        return prefix + canonicalSourceID(loadedArticle(forLinkToken: token)?.id ?? token)
    }

    /// The refs of `refs` that name something the library holds, as the
    /// cards they would be: a source by the id its Sources row has, a Doc, an
    /// Idea, a chat; a canvas other than the open one. A ref of a kind this
    /// does not know is left as it is.
    func knowledgeMapRefsInLibrary(_ refs: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in refs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let kind = String(trimmed[..<colon])
            let id = String(trimmed[trimmed.index(after: colon)...])
            guard !id.isEmpty else { continue }
            let ref: String
            switch kind {
            case "source":
                // What the Canvas shows: an active source the learner has not hidden.
                guard let article = loadedArticle(forLinkToken: id), article.status == .active, !article.isHidden else { continue }
                ref = "source:" + canonicalSourceID(article.id)
            case "doc":
                guard KnowledgeMapModel.mapArtifacts(artifacts).contains(where: { $0.id == id }) else { continue }
                ref = trimmed
            case "idea":
                guard ideas.contains(where: { $0.id == id && $0.status == .open }) else { continue }
                ref = trimmed
            case "chat":
                guard reviewSessionLinks.contains(where: { $0.id == id }) else { continue }
                ref = trimmed
            case "canvas":
                guard id != knowledgeMap.mapID, canvases.isInUse(id) else { continue }
                ref = trimmed
            default:
                ref = trimmed
            }
            if seen.insert(ref).inserted { out.append(ref) }
        }
        return out
    }

    /// **Add to Canvas ▸ <canvas>**: sets the cards `refs` name on the canvas.
    /// On the open canvas while it shows, in the middle of the view
    /// (`dropAtCenter`), selected. On the open canvas while it does not show,
    /// and on any other canvas, written into its layout row at a free spot,
    /// right of what it holds (the open canvas: the middle of the view it was
    /// last looking at), without opening it, and said in a toast with a Show
    /// button that opens it at the card. A card already on that canvas stays
    /// where it is.
    func addToCanvas(refs: [String], canvasID: String) async {
        guard listsCanvases, !isActiveLibraryReadOnly else { return }
        refreshCanvasesFromRows()
        // The window open on that canvas, this one before any other: its
        // model sets the cards down, so the write is one Undo step there.
        let open = knowledgeMapModel(showing: canvasID)
        let isOpenCanvas = open != nil
        guard isOpenCanvas || canvases.isInUse(canvasID) else {
            showToast("That canvas is no longer in your Space")
            return
        }
        let name = canvasNameForToast(canvasID)
        let wanted = knowledgeMapRefsInLibrary(refs)
        guard !wanted.isEmpty else {
            showToast("Nothing there can be placed on a canvas")
            return
        }
        let held = KnowledgeMapRows.layout(mapID: canvasID)
        let fresh = wanted.filter { held.placements[$0] == nil }
        let show = StudioToastAction(title: "Show") { [weak self] window in
            await self?.showCardOnCanvas(wanted[0], canvasID: canvasID, in: window)
        }
        guard !fresh.isEmpty else {
            showToast("Already on \(name)", action: show)
            return
        }

        if let open, knowledgeMapIsOnScreen(open) {
            await refreshKnowledgeMapContent(for: open)
            // The window turned to another canvas while the cards were read:
            // they go to the one asked for, written to its row as for a
            // canvas not showing.
            guard isShown(open) else {
                await addToCanvas(refs: wanted, canvasID: canvasID)
                return
            }
            let drawable = fresh.filter { open.nodesByRef[$0] != nil }
            guard !drawable.isEmpty else {
                showToast("That cannot be placed on \(name)")
                return
            }
            open.send(.dropAtCenter(refs: drawable, regionName: nil))
            return
        }

        if let open {
            // Not showing: the model writes it, as a drop would, so it is
            // one Undo step and its notebook frame hears of it.
            let spots = KnowledgeMapOutside.arrival(
                of: fresh,
                on: open.layout,
                height: open.cardHeight(of:),
                near: open.arrivalCenter()
            )
            open.place(spots)
        } else {
            let now = Date()
            let heights = knowledgeMap
            let layout = KnowledgeMapRows.update(mapID: canvasID, now: now) { row in
                let spots = KnowledgeMapOutside.arrival(of: fresh, on: row, height: heights.cardHeight(of:))
                for spot in spots { row.place(spot.ref, x: spot.x, y: spot.y, at: now.timeIntervalSince1970) }
            }
            canvases = canvases.setting(layout, for: canvasID)
        }
        showToast(fresh.count == 1 ? "Added to \(name)" : "Added \(fresh.count) cards to \(name)", action: show)
    }

    /// **New Canvas…** from an Add to Canvas ▸ menu: makes the canvas named
    /// `name` and adds the cards to it, then opens it where the learner is.
    func addToNewCanvas(refs: [String], named name: String, in windowState: StudioWindowState?) async {
        guard listsCanvases, !isActiveLibraryReadOnly else { return }
        let canvas = createCanvas(named: name)
        await addToCanvas(refs: refs, canvasID: canvas.id)
        guard let first = knowledgeMapRefsInLibrary(refs).first else {
            openCanvas(canvas.id, in: windowState)
            return
        }
        await showCardOnCanvas(first, canvasID: canvas.id, in: windowState)
    }

    /// What a New Canvas… from an Add to Canvas ▸ menu is named to start with:
    /// the one card's own title (a source's, a Doc's, an Idea's, a chat's),
    /// nothing for several cards.
    func canvasNameSuggestion(forRefs refs: [String]) -> String? {
        guard refs.count == 1, let colon = refs[0].firstIndex(of: ":") else { return nil }
        let kind = String(refs[0][..<colon])
        let id = String(refs[0][refs[0].index(after: colon)...])
        let title: String?
        switch kind {
        case "source": title = loadedArticle(forLinkToken: id).map { displayTitle(for: $0) }
        case "doc": title = artifacts.first { $0.id == id }?.title
        case "idea": title = ideas.first { $0.id == id }?.title
        case "chat": title = reviewSessionLinks.first { $0.id == id }?.title
        default: title = nil
        }
        return title.flatMap { KnowledgeMapCanvases.cleanedName($0) }
    }

    // MARK: On canvases

    /// Opens `canvasID` (in `windowState`, where the learner is, when nil)
    /// and flies to the card `ref`: what an "On canvases" name does, and a
    /// toast's Show.
    func showCardOnCanvas(_ ref: String, canvasID: String, in windowState: StudioWindowState?) async {
        let ref = canonicalKnowledgeMapRef(ref)
        let window = windowState ?? activeWindowState
        openCanvas(canvasID, in: window)
        // The canvas that just opened has no cards until the library has been
        // read for it; the focus waits for them or would find nothing.
        let opened = knowledgeMap(in: window)
        await refreshKnowledgeMapContent(for: opened)
        opened.send(.focus(refs: [ref], regionID: nil))
    }

    // MARK: Move to Canvas ▸

    /// Takes the placed cards `refs` off the open canvas, with the regions
    /// fully inside their bounds and the arrows between them, and writes them
    /// into canvas `canvasID`'s row, keeping where they are relative to each
    /// other, at a free spot there. The learner's one Undo step on this
    /// canvas takes them off it again (they stay on the other: Undo here
    /// never reaches into another canvas). Returns how many cards moved.
    @discardableResult
    func moveKnowledgeMapSelection(refs: [String], toCanvas canvasID: String) -> Int {
        guard listsCanvases, !isActiveLibraryReadOnly, canvasID != knowledgeMap.mapID else { return 0 }
        refreshCanvasesFromRows()
        guard canvases.isInUse(canvasID) else {
            showToast("That canvas is no longer in your Space")
            return 0
        }
        let map = knowledgeMap
        let source = map.layout
        let moved = KnowledgeMapOutside.moving(refs, from: source, height: map.cardHeight(of:))
        guard !moved.isEmpty else { return 0 }
        let now = Date()
        let layout = KnowledgeMapRows.update(mapID: canvasID, now: now) { row in
            KnowledgeMapOutside.write(moved, from: source, into: &row, height: map.cardHeight(of:), at: now.timeIntervalSince1970)
        }
        canvases = canvases.setting(layout, for: canvasID)
        // Another window open on the canvas they moved to draws them.
        reloadKnowledgeMaps(showing: canvasID)
        // Off this canvas, in the one burst the model keeps as one Undo step.
        for id in moved.edgeIDs where map.layout.edges[id] != nil { map.deleteEdge(id) }
        for id in moved.regionIDs where map.layout.regions[id] != nil { map.deleteRegion(id) }
        map.unplace(moved.refs)
        let name = canvasNameForToast(canvasID)
        let first = moved.refs[0]
        showToast(
            moved.refs.count == 1 ? "Moved to \(name)" : "Moved \(moved.refs.count) cards to \(name)",
            action: StudioToastAction(title: "Show") { [weak self] window in
                await self?.showCardOnCanvas(first, canvasID: canvasID, in: window)
            }
        )
        return moved.refs.count
    }

    // MARK: A chat's answer

    /// **Add to Canvas** on one answer in the chat pane: an Idea whose title
    /// is the answer's first sentence (120 characters at most) and whose note
    /// is the answer as it was written, with the sources it cites linked as
    /// the Idea's evidence, set on the open canvas as an Add to Canvas does.
    func addAnswerToCanvas(markdown: String) async {
        guard listsCanvases, !isActiveLibraryReadOnly else { return }
        let answer = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = KnowledgeMapOutside.firstSentence(of: answer)
        guard !title.isEmpty else {
            showToast("That answer has no words to put on a canvas")
            return
        }
        let canvasID = knowledgeMap.mapID
        guard let idea = await createIdea(title: title, notes: answer) else { return }
        let cited = librarySourceIDs(forBlockLinks: ChatSourceEvidence.sourceLinkTokens(in: answer)).map(canonicalSourceID)
        var unique: Set<String> = []
        let sourceIDs = cited.filter { unique.insert($0).inserted }
        if !sourceIDs.isEmpty {
            await linkIdea(ideaID: idea.id, kind: .source, targetIDs: sourceIDs)
        }
        await addToCanvas(refs: [KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description], canvasID: canvasID)
    }

    // MARK: Files, pictures, chats, addresses and words

    /// Makes cards of what came onto the Canvas from outside it, and returns
    /// their refs for the page to set down where it landed (`dropAt`). Each
    /// is brought into the library first (a PDF as a paper, a Markdown or text
    /// file as a source, a picture into the Images library, an address
    /// through the library's one URL import) and only a success is returned;
    /// a failure is said in a toast with its reason. A toast says what is
    /// being imported meanwhile. Words pasted are written as an Idea at the
    /// middle of the view and not returned.
    func knowledgeMapOutsideRefs(_ drop: KnowledgeMapOutsideDrop, on model: KnowledgeMapModel? = nil) async -> [String] {
        // The canvas it came onto, kept across the imports.
        let knowledgeMap = model ?? self.knowledgeMap
        defer {
            if let folder = drop.stagingDirectory { try? FileManager.default.removeItem(at: folder) }
        }
        var refs: [String] = []
        var failures: [String] = []
        let total = drop.fileURLs.count + drop.pictures.count + drop.links.count

        for url in drop.fileURLs {
            let name = url.lastPathComponent
            switch KnowledgeMapOutside.fileKind(forExtension: url.pathExtension) {
            case .paper:
                PaperIngestionDiagnostics.recordDropAccepted(filename: name)
                do {
                    let sourceID = try await whileShowing(total > 1 ? "Importing \(total) items…" : "Importing \(name)…") {
                        try await importPDF(
                            from: url.path,
                            revealInLibrary: false,
                            reportsExistingPaper: false,
                            selectInReader: false
                        )
                    }
                    PaperIngestionDiagnostics.recordDropImported(filename: name, sourceID: sourceID)
                    refs.append(KnowledgeMap.ItemRef(kind: .source, id: canonicalSourceID(sourceID)).description)
                } catch {
                    PaperIngestionDiagnostics.recordDropFailure(filename: name, message: error.localizedDescription)
                    failures.append("\(name): \(error.localizedDescription)")
                }
            case .textSource where drop.stagingDirectory != nil:
                // A text source keeps the path of the file it was read from, and a
                // file an app handed over is in a folder of ours that goes away.
                failures.append("\(name): save it to a folder and drop it from there")
            case .textSource:
                switch await whileShowing(total > 1 ? "Importing \(total) items…" : "Importing \(name)…", { await importTextFileForCanvas(at: url) }) {
                case .success(let sourceID):
                    refs.append(KnowledgeMap.ItemRef(kind: .source, id: canonicalSourceID(sourceID)).description)
                case .failure(let reason):
                    failures.append("\(name): \(reason)")
                }
            case .picture:
                do {
                    let imageID = try await whileShowing(total > 1 ? "Importing \(total) items…" : "Importing \(name)…") {
                        let data = try await Task.detached(priority: .userInitiated) {
                            try Data(contentsOf: url, options: .mappedIfSafe)
                        }.value
                        return try await keepPictureFromCanvas(
                            data,
                            named: url.deletingPathExtension().lastPathComponent,
                            from: name
                        )
                    }
                    refs.append(KnowledgeMapOutside.pictureRef(imageID))
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            case let kind:
                failures.append(KnowledgeMapOutside.refusal(forFileNamed: name, kind: kind))
            }
        }

        for picture in drop.pictures {
            do {
                let imageID = try await whileShowing(total > 1 ? "Importing \(total) items…" : "Keeping the picture…") {
                    try await keepPictureFromCanvas(picture.data, named: picture.name, from: "the clipboard")
                }
                refs.append(KnowledgeMapOutside.pictureRef(imageID))
            } catch {
                failures.append("\(picture.name): \(error.localizedDescription)")
            }
        }

        for address in drop.links {
            let outcome = await whileShowing(total > 1 ? "Importing \(total) items…" : "Adding \(address)…") {
                await importLink(address, intoNotebook: nil)
            }
            if case .failed(let reason) = outcome.library {
                failures.append("\(address): \(reason)")
            } else if let sourceID = outcome.sourceID {
                refs.append(KnowledgeMap.ItemRef(kind: .source, id: canonicalSourceID(sourceID)).description)
            } else {
                failures.append("\(address): it could not be added")
            }
        }

        let chats = drop.chatIDs.filter { id in reviewSessionLinks.contains { $0.id == id } }
        refs.append(contentsOf: chats.map(KnowledgeMapOutside.chatRef))
        if chats.count < drop.chatIDs.count { failures.append("That chat is no longer in your library") }
        refs.append(contentsOf: knowledgeMapRefsInLibrary(drop.cardRefs))

        if let text = drop.text, let idea = KnowledgeMapOutside.idea(fromPasted: text) {
            await placePastedIdea(title: idea.title, notes: idea.notes, on: knowledgeMap)
        }

        // The page draws only the cards the model has read from the library,
        // and a source or picture just brought in is not among them yet.
        if !refs.isEmpty {
            await refreshKnowledgeMapContent(for: knowledgeMap)
            let shown = refs.filter { knowledgeMap.nodesByRef[$0] != nil }
            if shown.count < refs.count {
                failures.append(refs.count - shown.count == 1 ? "one item cannot be shown on the canvas" : "\(refs.count - shown.count) items cannot be shown on the canvas")
            }
            refs = shown
        }

        if !failures.isEmpty {
            showToast(refs.isEmpty ? failures.joined(separator: "\n") : "Placed \(refs.count), but: " + failures.joined(separator: "; "))
        } else if !refs.isEmpty, total > 0 {
            // The "Importing…" line is done; the cards say the rest.
            dismissToast()
        }
        return refs
    }

    /// Runs `work` with `message` in the toast the whole while: a toast closes
    /// itself after a few seconds, and an import can take much longer.
    private func whileShowing<T>(_ message: String, _ work: () async throws -> T) async rethrows -> T {
        showToast(message)
        let keeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                self?.showToast(message)
            }
        }
        defer { keeper.cancel() }
        return try await work()
    }

    /// Words pasted: an Idea at the middle of the view, through the note a
    /// double-click writes when it is a few words, with the whole text as its
    /// note when it is more.
    private func placePastedIdea(title: String, notes: String?, on knowledgeMap: KnowledgeMapModel) async {
        let spots = KnowledgeMapOutside.arrival(
            of: ["new"],
            on: knowledgeMap.layout,
            height: { _ in KnowledgeMap.cardHeight },
            near: knowledgeMap.arrivalCenter()
        )
        guard let spot = spots.first else { return }
        guard let notes else {
            await createKnowledgeMapNote(title, at: (spot.x, spot.y), on: knowledgeMap)
            return
        }
        let canvas = knowledgeMap
        guard let idea = await createIdea(title: title, notes: notes) else { return }
        await refreshKnowledgeMapContent(for: canvas)
        canvas.place([(ref: KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description, x: spot.x, y: spot.y)])
    }

    private enum TextImport {
        case success(String)
        case failure(String)
    }

    /// A Markdown or text file as a source: the one the library holds for
    /// that file already, else a new one through the library's text import.
    private func importTextFileForCanvas(at url: URL) async -> TextImport {
        let path = url.path
        if let held = articles.first(where: { $0.url == path || $0.localFilePath == path }) {
            return .success(held.id)
        }
        let known = Set(articles.map(\.id))
        let previousError = errorMessage
        do {
            try await importTextFile(from: path)
        } catch {
            return .failure(error.localizedDescription)
        }
        if let made = articles.first(where: { !known.contains($0.id) }) { return .success(made.id) }
        let reason = errorMessage != previousError ? errorMessage : nil
        return .failure(reason ?? "there was no text in it")
    }

    /// Keeps a picture from a drop or a paste in the Images library, as a
    /// picture made elsewhere, and returns its image id (the `picture:` card's
    /// id). `source` names where it came from, for the prompt a picture is
    /// never kept without.
    private func keepPictureFromCanvas(_ data: Data, named name: String, from source: String) async throws -> String {
        guard !data.isEmpty else { throw KnowledgeMapOutsideError.emptyPicture }
        guard data.count <= KnowledgeMapOutside.maximumPictureBytes else {
            throw KnowledgeMapOutsideError.pictureTooLarge(megabytes: data.count / 1_048_576)
        }
        let title = GeneratedImageStore.cleanTitle(name)
        let stored = try await Task.detached(priority: .userInitiated) { () throws -> GeneratedImageStore.Listing in
            guard let mediaType = GeneratedImageStore.mediaType(of: data) else {
                throw KnowledgeMapOutsideError.notAPicture
            }
            return try GeneratedImageStore.store(
                GeneratedImage(data: data, mediaType: mediaType),
                origin: .saved,
                text: "A picture placed on the Canvas from \(source).",
                title: title ?? "Picture on the Canvas",
                model: nil,
                revising: nil
            )
        }.value
        return stored.imageID
    }
}

enum KnowledgeMapOutsideError: LocalizedError {
    case emptyPicture
    case pictureTooLarge(megabytes: Int)
    case notAPicture

    var errorDescription: String? {
        switch self {
        case .emptyPicture: return "the picture is empty"
        case .pictureTooLarge(let megabytes): return "the picture is \(megabytes) MB; the most the Images library keeps is 20 MB"
        case .notAPicture: return "that is not a picture this Mac can read"
        }
    }
}

// MARK: - Which canvases hold a card

/// `ref → canvases` over every canvas's layout row, rebuilt for a canvas only
/// when its last activity moves (a write changes it), so a list of rows that
/// each ask "which canvases hold this?" parses each row once.
@MainActor
final class KnowledgeMapPlacementIndex {
    static let shared = KnowledgeMapPlacementIndex()

    private var activity: [String: Double] = [:]
    private var refsByCanvas: [String: Set<String>] = [:]

    func canvasIDs(holding ref: String, among canvases: [KnowledgeMapCanvas]) -> Set<String> {
        let current = Dictionary(canvases.map { ($0.id, $0.updatedAt.timeIntervalSince1970) }, uniquingKeysWith: { first, _ in first })
        if current != activity {
            for (id, at) in current where activity[id] != at {
                refsByCanvas[id] = Set(KnowledgeMapRows.layout(mapID: id).placements.keys)
            }
            for id in refsByCanvas.keys where current[id] == nil { refsByCanvas.removeValue(forKey: id) }
            activity = current
        }
        return Set(refsByCanvas.filter { $0.value.contains(ref) }.keys)
    }
}
