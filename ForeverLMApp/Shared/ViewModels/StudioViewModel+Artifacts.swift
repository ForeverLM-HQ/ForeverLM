import Foundation

extension StudioViewModel {
    func loadArtifacts() async {
        guard !isLoadingArtifacts else { return }
        isLoadingArtifacts = true
        defer { isLoadingArtifacts = false }
        do {
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Loading artifacts failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        await refreshArtifactWalkthroughIDs()
        await refreshArtifactTeamIDs()
        hasLoadedArtifactsOnce = true
    }

    /// Which teams each My Library artifact is in (`artifactTeamIDs`). A team
    /// library lists only its own rows, so there is nothing to tell apart.
    func refreshArtifactTeamIDs() async {
        guard activeTeamID == nil else {
            artifactTeamIDs = [:]
            return
        }
        do {
            artifactTeamIDs = try await storage.teamIDsByMyLibraryArtifact()
        } catch {
            logger.warning("Reading which teams hold each artifact failed: \(error.localizedDescription)")
        }
    }

    /// The records filed in a Notebook — homed on it or linked to it
    /// (`NotebookOutputs.isFiled`, the notebook's Studio's rule) — archived
    /// and hidden ones included, for lists with filters of their own.
    func linkedArtifacts(notebookID: String) -> [ArtifactRecord] {
        artifacts.filter { NotebookOutputs.isFiled($0, in: notebookID) }
    }

    /// A new page, filed in `pageSpaceID` when one is given: New page while
    /// a space is the Space's chosen place (docs/docs-design.md, "The Space").
    func createArtifact(
        title: String,
        homeNotebookID: String?,
        linkedNotebookIDs: [String],
        markdown: String = "",
        pageSpaceID: String? = nil
    ) async throws -> ArtifactMarkdownSnapshot {
        let snapshot = try await storage.createArtifact(
            title: title,
            homeNotebookID: homeNotebookID,
            linkedNotebookIDs: linkedNotebookIDs,
            markdown: markdown,
            teamID: activeTeamID
        )
        if let pageSpaceID {
            filePages([snapshot.artifact.id], inPageSpace: pageSpaceID)
        }
        artifacts = try await loadScopedArtifacts()
        showToast("Created \(snapshot.artifact.title)")
        return snapshot
    }

    /// A new Doc whose body may show pictures by their `foreverlm://image/…`
    /// address, as a chat answer does, made the way MCP `create_doc` makes one
    /// (`MCPDataStore.createArtifact`): every picture is rendered first, and
    /// one this Mac cannot draw refuses the save, so no Doc is kept with a
    /// broken picture; the Doc is created with an empty body, keeps the
    /// pictures as its own attachments, and its body is written once, every
    /// line naming the Doc's copy. No version with an image address ever
    /// syncs, and there is no second write. A team notebook's Doc keeps them
    /// too: unlike `keepingDocPictures` on open, this is the author's own new
    /// write. Save to note under a chat answer makes its Doc here.
    func createDocKeepingPictures(
        title: String,
        homeNotebookID: String?,
        markdown: String
    ) async throws -> ArtifactMarkdownSnapshot {
        let rendering = DocPictureLines.addresses(in: markdown).isEmpty
            ? DocPictureRendering()
            : await storage.renderDocPictures(in: markdown)
        if let failure = rendering.failures.first {
            throw ArtifactError.pictureUnavailable(failure.reason)
        }
        var snapshot = try await storage.createArtifact(
            title: title,
            homeNotebookID: homeNotebookID,
            linkedNotebookIDs: [],
            markdown: rendering.pictures.isEmpty ? markdown : "",
            teamID: activeTeamID
        )
        if !rendering.pictures.isEmpty {
            // The pictures are kept in the new Doc's own folder, which exists
            // once the Doc does; the body that names them follows.
            let id = snapshot.artifact.id
            do {
                let body = try await storage.keepDocPictures(rendering.pictures, in: markdown, artifactID: id)
                snapshot = try await storage.writeArtifactMarkdownAndSync(
                    artifactID: id,
                    markdown: body.markdown,
                    expectedRevision: snapshot.revision
                )
            } catch {
                try? await storage.deleteArtifact(id)
                throw error
            }
        }
        artifacts = try await loadScopedArtifacts()
        showToast("Created \(snapshot.artifact.title)")
        return snapshot
    }

    func artifactMarkdown(_ artifactID: String) async throws -> ArtifactMarkdownSnapshot {
        try await storage.artifactMarkdown(artifactID)
    }

    /// A doc opened with picture lines that name a picture by its
    /// `foreverlm://image/…` address — saved before docs kept their pictures,
    /// or written on a Mac that did not hold them — keeps every such picture
    /// this Mac can render as its own attachment, and is saved with them, so
    /// it draws here and on every device it reaches. A picture this Mac cannot
    /// render stays as written for a Mac that can. A team doc is the team's
    /// page, not this member's to rewrite on open.
    func keepingDocPictures(of snapshot: ArtifactMarkdownSnapshot) async -> ArtifactMarkdownSnapshot {
        let artifact = snapshot.artifact
        guard !artifact.isLinked, artifact.teamID == nil,
              !DocPictureLines.addresses(in: snapshot.markdown).isEmpty else { return snapshot }
        let rendering = await storage.renderDocPictures(in: snapshot.markdown)
        for failure in rendering.failures {
            logger.warning("Doc \(artifact.id) keeps a picture it cannot show on this Mac: \(failure.address): \(failure.reason)")
        }
        guard !rendering.pictures.isEmpty else { return snapshot }
        do {
            let body = try await storage.keepDocPictures(rendering.pictures, in: snapshot.markdown, artifactID: artifact.id)
            // Not `saveArtifactMarkdown`: opening a doc is not writing one, so
            // the day's log does not hear of it.
            let saved = try await storage.writeArtifactMarkdownAndSync(
                artifactID: artifact.id,
                markdown: body.markdown,
                expectedRevision: snapshot.revision
            )
            if let reloaded = try? await loadScopedArtifacts() { artifacts = reloaded }
            return saved
        } catch {
            logger.error("Keeping doc \(artifact.id)'s pictures failed: \(error.localizedDescription)")
            return snapshot
        }
    }

    /// The artifacts a source is linked to — grounded on it, or citing it —
    /// for the sidebar row's and the reader's **Linked in** menu, resolved
    /// when the menu opens and off the main actor (docs/docs-design.md,
    /// "Linked in"). Hidden records stay out; archived ones are listed.
    func linkedArtifacts(forSource sourceID: String) async -> [StorageService.SourceArtifactLink] {
        let links = (try? await storage.artifactsLinked(toSource: sourceID)) ?? []
        return links.filter { !$0.artifact.isHidden }
    }

    /// Another writer's version of a Doc body the sync engine could not merge
    /// into this Mac's, held beside the doc until the writer picks one
    /// (docs/teams-design.md, decision 12). nil when nothing is held.
    func artifactHeldRemoteMarkdown(_ artifactID: String) async -> String? {
        try? await storage.artifactHeldRemoteMarkdown(artifactID)
    }

    func discardArtifactHeldRemoteMarkdown(_ artifactID: String) async {
        do {
            try await storage.discardArtifactHeldRemoteMarkdown(artifactID)
        } catch {
            logger.error("Discarding the held version of doc \(artifactID) failed: \(error.localizedDescription)")
        }
    }

    func saveArtifactMarkdown(
        artifactID: String,
        markdown: String,
        expectedRevision: String,
        versionReason: PageVersionReason = .learnerEdit
    ) async throws -> ArtifactMarkdownSnapshot {
        let snapshot = try await storage.writeArtifactMarkdownAndSync(
            artifactID: artifactID,
            markdown: markdown,
            expectedRevision: expectedRevision,
            versionReason: versionReason
        )
        // The save wrote one record, so the list takes that record and is
        // otherwise left alone, and only when what it shows changes: the
        // page's place, or its date by a minute (`ArtifactListOrder`). Saves
        // come at each pause in typing; reading the library's list back on
        // every one redrew every view that lists pages while the learner wrote.
        if let move = ArtifactListOrder.move(afterSaving: snapshot.artifact, in: artifacts) {
            ArtifactListOrder.apply(move, saving: snapshot.artifact, to: &artifacts)
        }
        // The Planner's log: a page being written is a thing the day was
        // spent on. The log counts minutes, so it hears of a page once a minute.
        let title = snapshot.artifact.title
        if pageWritingMinutes.admits(artifactID, title: title, at: Date()) {
            do {
                try await storage.recordDayActivity(kind: .doc, targetID: artifactID, title: title)
            } catch {
                pageWritingMinutes.forget(artifactID)
                logger.error("Failed to log the doc save in the day's log: \(error.localizedDescription)")
            }
        }
        return snapshot
    }

    func updateArtifact(
        artifactID: String,
        title: String? = nil,
        homeNotebookID: String? = nil,
        linkedNotebookIDs: [String]? = nil,
        isDraft: Bool? = nil,
        isArchived: Bool? = nil
    ) async {
        do {
            _ = try await storage.updateArtifact(
                artifactID: artifactID,
                title: title,
                homeNotebookID: homeNotebookID,
                linkedNotebookIDs: linkedNotebookIDs,
                isDraft: isDraft,
                isArchived: isArchived
            )
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Updating artifact failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Hides a doc or site from the Docs and Sites lists, or shows it again,
    /// on every Mac signed into this account. Nothing about the record moves;
    /// the hide syncs as a record of its own, and the Hidden filter is where
    /// the doc is found and shown again.
    func setArtifactHidden(artifactID: String, isHidden: Bool) async {
        do {
            _ = try await storage.setArtifactHidden(artifactID: artifactID, isHidden: isHidden)
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Hiding artifact failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Files a doc under one more Notebook, or takes it out of one, from the
    /// doc's own menu. The home Notebook follows: a doc joining its first
    /// Notebook makes that its home, and a doc leaving its home hands the home
    /// to another Notebook it is still filed under, or to none.
    func setArtifactNotebookMembership(_ artifactID: String, notebookID: String, isMember: Bool) async {
        guard let artifact = artifacts.first(where: { $0.id == artifactID }) else { return }
        var linked = artifact.linkedNotebookIDs.filter { $0 != notebookID }
        if isMember { linked.append(notebookID) }
        var home: String?
        if isMember, artifact.homeNotebookID == nil { home = notebookID }
        if !isMember, artifact.homeNotebookID == notebookID { home = linked.first ?? "" }
        await updateArtifact(artifactID: artifactID, homeNotebookID: home, linkedNotebookIDs: linked)
    }

    /// Follows a link to one of the app's own things: the doc comes forward in
    /// Docs, the Notebook opens in Notebooks, the chat resumes in the chat panel,
    /// a course quiz is taken (or picked up where it stopped) in its own chat.
    /// A target that is gone says so instead of doing nothing.
    func open(_ link: StudioEntityLink) async {
        switch link {
        case .doc(let id):
            if !artifacts.contains(where: { $0.id == id }) { await loadArtifacts() }
            guard artifacts.contains(where: { $0.id == id }) else {
                showToast("That page is no longer in your library")
                return
            }
            revealArtifact(id)
        case .notebook(let id):
            guard notebook(id: id) != nil else {
                showToast("That notebook is no longer in your library")
                return
            }
            openNotebookInReader(id)
        case .chat(let id):
            // The sidebar's list can lag a chat another window or the plugin
            // just made, so a miss asks storage once before giving up.
            if !reviewSessionLinks.contains(where: { $0.id == id }) { await loadReviewSessionLinks() }
            guard reviewSessionLinks.contains(where: { $0.id == id }) else {
                showToast("That chat is no longer in your library")
                return
            }
            requestResumeReviewSession(id)
        case .quiz(let id):
            // A quiz written a moment ago (on another Mac, or over MCP) may
            // not be in the loaded ladder yet.
            if courseQuiz(id) == nil { await refreshCourseQuizzes() }
            takeCourseQuiz(id)
        case .idea(let id):
            await openIdea(id)
        }
    }

    // MARK: - Reference cards

    /// The library a Doc's reference cards answer to. A team Doc's cards ask
    /// the team library and nothing else — a paper one member holds privately
    /// is not in the team's library, so every member sees Add to Sources until
    /// someone adds it for the team. A member's draft of a team Doc is that
    /// team's too, so the cards do not flip when Edit is pressed. A Doc in My
    /// Library asks My Library.
    func referenceLibraryTeamID(for artifact: ArtifactRecord) -> String? {
        if let teamID = artifact.teamID { return teamID }
        if let teamArtifactID = teamArtifactID(forDraft: artifact.id) {
            return artifacts.first { $0.id == teamArtifactID }?.teamID
        }
        return nil
    }

    /// What the library says about each web reference a doc holds — the lines
    /// the editor draws as cards. The lookup runs on the storage lane; the
    /// answer is keyed by the address exactly as the editor sent it. `teamID`
    /// is the Doc's library (`referenceLibraryTeamID(for:)`), nil for My Library.
    func referenceLibraryStatuses(for hrefs: [String], teamID: String? = nil) async -> [String: ArtifactReferenceStatus] {
        guard !hrefs.isEmpty else { return [:] }
        let matches = await storage.librarySourceIDs(forReferenceURLs: hrefs, teamID: teamID)
        var statuses: [String: ArtifactReferenceStatus] = [:]
        for href in hrefs {
            statuses[href] = matches[href].map(ArtifactReferenceStatus.inLibrary) ?? .absent
        }
        return statuses
    }

    /// Add to Sources on a reference card: the same path as pasting the address
    /// into the sidebar, with the reader left where it is. An older removal of
    /// the same source is superseded, because the click is an explicit re-add.
    /// The answer is the card's next state — the library is asked again rather
    /// than trusted to have inserted, because `addArticle` reports a duplicate
    /// or a refusal through `errorMessage` instead of throwing, and a duplicate
    /// of a paper already saved is, to the card, simply in the library.
    ///
    /// On a team Doc (`teamID` set) the card means the team's library: the
    /// import saves the learner's own row the way every import does, and the
    /// row is then copied into that team, whichever library is open — so the
    /// check the member sees next is the one every teammate will see. A member
    /// who cannot edit the team cannot add for it, and is told so instead of
    /// quietly filing the paper somewhere the card does not look.
    func addReferenceToLibrary(_ href: String, teamID: String? = nil) async -> ArtifactReferenceStatus {
        if let teamID {
            guard let team = team(id: teamID) else {
                return .failed("This team is no longer on this Mac.")
            }
            guard team.canEdit else {
                return .failed("Only an editor of \(team.name) can add sources to its library.")
            }
        }
        let errorBefore = errorMessage
        do {
            try await addArticle(url: href, revealInReader: false, reviveArchivedSourceIfNeeded: true)
        } catch {
            errorMessage = "Couldn't add the source: \(error.localizedDescription)"
        }
        if let teamID,
           await storage.librarySourceIDs(forReferenceURLs: [href], teamID: teamID)[href] == nil,
           let ownID = await storage.librarySourceIDs(forReferenceURLs: [href])[href] {
            await shareSources([ownID], withTeam: teamID)
        }
        if let id = await storage.librarySourceIDs(forReferenceURLs: [href], teamID: teamID)[href] {
            return .inLibrary(sourceID: id)
        }
        let reason = errorMessage != errorBefore ? errorMessage : nil
        return .failed(reason ?? "The source could not be added.")
    }

    func deleteArtifact(_ artifactID: String) async {
        do {
            try await storage.deleteArtifact(artifactID)
            artifacts = try await loadScopedArtifacts()
            showToast("Moved note to Trash")
        } catch {
            logger.error("Deleting artifact failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// **Move to Trash** on a page, a linked Google Doc or a site, from the
    /// Space, a page's menu or its row (docs/docs-design.md, "The Space"). The
    /// Space's Trash is the archive: the record is put away whole — its body,
    /// its page, its notebook links — and leaves every list but Trash, where
    /// Restore brings it back and Delete Forever removes it. Until 2026-10-06
    /// Move to Trash deleted the record outright and only its folder reached
    /// the Finder's Trash, so nothing in the app could undo a slipped click.
    ///
    /// A page goes with the pages nested under it, as a Codex page's Delete
    /// takes its subpages ("This page and its subpages will move to Trash",
    /// docs/codex-parity-audit.md, 1B); until 2026-10-13 they stayed behind at
    /// the top of the lists. Each is in Trash on its own and restored there.
    /// The toast says what went, and its Undo brings back exactly that; the
    /// page menu asks first when subpages would go too (`PageTrashWording`).
    func moveArtifactToTrash(_ artifactID: String) async {
        let going = [artifactID] + pageTree.descendantIDs(of: artifactID)
        let title = artifacts.first { $0.id == artifactID }?.title ?? ""
        let trashed = await setArchived(going, isArchived: true)
        guard trashed.contains(artifactID) else { return }
        showToast(
            PageTrashWording.toast(title: title, subpageCount: trashed.count - 1),
            undo: { [weak self] in
                guard let self else { return }
                if await self.setArchived(trashed, isArchived: false).count == trashed.count {
                    self.showToast("Restored")
                }
            }
        )
    }

    /// Puts records in Trash or takes them out, then reads the list once.
    /// Stops at the first failure and says it; answers the ids that changed.
    private func setArchived(_ artifactIDs: [String], isArchived: Bool) async -> [String] {
        var changed: [String] = []
        for artifactID in artifactIDs {
            do {
                _ = try await storage.updateArtifact(
                    artifactID: artifactID,
                    title: nil,
                    homeNotebookID: nil,
                    linkedNotebookIDs: nil,
                    isArchived: isArchived
                )
                changed.append(artifactID)
            } catch {
                logger.error("\(isArchived ? "Moving" : "Restoring") \(artifactID) failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                break
            }
        }
        do {
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Reloading artifacts after a Trash move failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        return changed
    }

    /// **Restore** in the Space's Trash: the record is current again, in every
    /// list it was in.
    func restoreArtifactFromTrash(_ artifactID: String) async {
        await updateArtifact(artifactID: artifactID, isArchived: false)
        if artifacts.first(where: { $0.id == artifactID })?.isArchived == false {
            showToast("Restored")
        }
    }

    /// **Delete Forever** and **Empty Trash**: the records go for good — the
    /// row, its sync record and its folder, which moves to the Finder's Trash
    /// (`StorageService.deleteArtifact`). A linked Google Doc or site loses
    /// only its link: the page it pointed at is not ForeverLM's to delete.
    /// Stops at the first failure and says which, leaving the rest in Trash.
    func deleteArtifactsForever(_ artifactIDs: [String]) async {
        guard !artifactIDs.isEmpty else { return }
        var deleted: [String] = []
        for artifactID in artifactIDs {
            do {
                try await storage.deleteArtifact(artifactID)
                deleted.append(artifactID)
            } catch {
                logger.error("Deleting artifact forever failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                break
            }
        }
        // A page gone for good leaves its space (`PageSpaces`).
        forgetPageSpaces(of: deleted)
        forgetPageParents(of: deleted)
        do {
            artifacts = try await loadScopedArtifacts()
        } catch {
            logger.error("Reloading artifacts after a delete failed: \(error.localizedDescription)")
        }
        guard !deleted.isEmpty else { return }
        showToast(deleted.count == 1 ? "Deleted forever" : "Deleted \(deleted.count) items forever")
    }

    /// Put a whole Doc into Chat's context.
    ///
    /// The selection handoff answers "explain this passage" and deliberately
    /// replaces the pool it lands in. This answers "work with this document",
    /// so it is additive and leaves the open conversation alone — the same
    /// contract a dropped source gets.
    ///
    /// It attaches the stored revision, not the editor's unsaved draft: that is
    /// the text `read_doc` will return, so the two cannot disagree about
    /// what the chat is holding.
    ///
    /// Docs → **Edit with AI**: answer the editor's request for a revised
    /// passage on the Docs model (`KeychainService.resolveDocsConfig`: Docs'
    /// own, else the Default Model; never the open chat's pick). Nothing is
    /// written here — the editor shows the proposal and the writer chooses
    /// Replace or Insert below — and a failure is thrown to the panel rather
    /// than masked.
    func editDocPassageWithAI(_ request: DocPassageEditRequest) async throws -> String {
        guard let config = KeychainService.resolveDocsConfig() else {
            throw DocPassageEditError.noModel
        }
        return try await aiService.editDocPassage(request, config: config)
    }

    /// Chat opens beside Docs, on its right, the same side a passage handoff
    /// puts it; the doc the gesture came from keeps its pane.
    func attachDocToChat(_ artifactID: String) async {
        do {
            let snapshot = try await artifactMarkdown(artifactID)
            pendingChatDocAttachment = ChatDocAttachment(snapshot: snapshot)
            revealChat(beside: .notepad)
            showToast("Added \(snapshot.artifact.title) to Chat")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func artifactFileURL(_ artifactID: String) async -> URL? {
        do {
            return try await storage.artifactFileURL(artifactID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importArtifactImage(_ url: URL, artifactID: String) async throws -> ArtifactAttachment {
        try await storage.importArtifactImage(url, artifactID: artifactID)
    }

    /// Docs → **File**: a file the writer chose, kept in the page's Attachments.
    func importArtifactFile(_ url: URL, artifactID: String) async throws -> ArtifactFileAttachment {
        try await storage.importArtifactFile(url, artifactID: artifactID)
    }

    /// Where an attached file is kept, for **Save file…**; refuses a token this
    /// app did not write.
    func artifactAttachmentFileURL(_ artifactID: String, token: String) async throws -> URL {
        try await storage.artifactAttachmentFileURL(artifactID: artifactID, token: token)
    }

    /// Docs → **Generate image**: draw the picture the writer described with
    /// the account's image model (Settings › Images, the model the chat's and
    /// the assistants' `generate_image` use; never named here), keep it in the
    /// doc's Attachments, and hand the editor what it draws it from. The route
    /// and its ledger row are `ManagedImageGeneration`'s, filed under
    /// `doc_image`. A failure — signed out, a refusing provider, a model that
    /// returned nothing — is thrown for the panel to say, never
    /// swallowed and never answered with another model's picture.
    ///
    /// Landscape at medium quality: a figure in a page is wider than tall, and
    /// the writer was not asked for more than the description.
    func generateDocImage(prompt: String, artifactID: String) async throws -> ArtifactGeneratedImage {
        let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw ManagedImageGeneration.Failure.emptyPrompt }
        // Refused before anything is spent when the doc cannot keep a picture.
        if let doc = artifacts.first(where: { $0.id == artifactID }), doc.isLinked {
            throw ArtifactError.linkedDocReadOnly(doc.title)
        }
        let image = try await ManagedImageGeneration.generate(
            prompt: description,
            model: MacImageGenerationSettings.model,
            shape: .landscape,
            quality: .medium,
            usageTask: "doc_image"
        )
        let altText = ArtifactGeneratedImage.altText(forPrompt: description)
        let kept = try await storage.storeGeneratedArtifactImage(
            image.data,
            mediaType: image.mediaType,
            altText: altText,
            artifactID: artifactID
        )
        return ArtifactGeneratedImage(token: kept.attachment.token, dataURL: kept.dataURL, altText: altText)
    }

    func artifactAttachmentDataURLs(
        _ artifactID: String,
        markdown: String
    ) async throws -> [String: String] {
        try await storage.artifactAttachmentDataURLs(artifactID, markdown: markdown)
    }

    func artifactComments(_ artifactID: String) async throws -> [ArtifactCommentRecord] {
        try await storage.artifactComments(artifactID)
    }

    /// The chats this doc's passages started. Paired with the session record so
    /// a row can say what the conversation was called and when it happened,
    /// rather than showing a bare anchor.
    func artifactChatLinks(_ artifactID: String) async -> [ArtifactChatLink] {
        let links: [ArtifactChatLinkRecord]
        do {
            links = try await storage.artifactChatLinks(artifactID)
        } catch {
            logger.error("Failed to load a doc's chat links: \(error.localizedDescription)")
            return []
        }
        guard !links.isEmpty else { return [] }
        if reviewSessionLinks.isEmpty { await loadReviewSessionLinks() }
        let sessionsByID = Dictionary(
            reviewSessionLinks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // A link whose chat is gone is not a chat: deleting a conversation
        // cascades the row away locally, but a store that received the delete
        // out of order can still hold one, and a dangling row would draw an
        // untappable ghost on the doc.
        return links.compactMap { link in
            guard let session = sessionsByID[link.sessionID] else { return nil }
            return ArtifactChatLink(link: link, session: session)
        }
        .sorted { $0.link.createdAt > $1.link.createdAt }
    }

    /// The doc passages one conversation was opened on. The mirror of
    /// `artifactChatLinks(_:)`, read from the chat's side.
    func chatDocLinks(sessionID: String) async -> [ArtifactChatLink] {
        let links: [ArtifactChatLinkRecord]
        do {
            links = try await storage.chatLinksForSession(sessionID)
        } catch {
            logger.error("Failed to load a chat's doc links: \(error.localizedDescription)")
            return []
        }
        guard !links.isEmpty else { return [] }
        if reviewSessionLinks.isEmpty { await loadReviewSessionLinks() }
        guard let session = reviewSessionLinks.first(where: { $0.id == sessionID }) else { return [] }
        // Only docs this library still holds: a link whose doc was deleted on
        // another Mac would draw a chip that opens nothing. The list has to be
        // read before that judgement can be made — a chat reopened before the
        // docs have loaded would otherwise decide every one of its links points
        // at a missing doc, and this lookup does not run again on its own.
        if artifacts.isEmpty { await loadArtifacts() }
        let known = Set(artifacts.map(\.id))
        return links
            .filter { known.contains($0.artifactID) }
            .map { ArtifactChatLink(link: $0, session: session) }
    }

    func forgetArtifactChatLink(_ linkID: String) async {
        do {
            try await storage.deleteArtifactChatLink(linkID)
        } catch {
            logger.error("Failed to forget a doc's chat link: \(error.localizedDescription)")
        }
    }

    func addArtifactComment(
        artifactID: String,
        body: String,
        selection: ArtifactEditorSelection
    ) async throws -> ArtifactCommentRecord {
        // The author is this account as the library container names it, the same id the web reads.
        guard let coordinator = SyncCoordinator.current else { throw SpaceServiceError.syncNotRunning }
        let userID = try await coordinator.transport.userRecordName()
        let displayName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return try await storage.addArtifactCommentAndSync(
            artifactID: artifactID,
            authorRecordName: userID,
            authorDisplayName: displayName.isEmpty ? "Collaborator" : displayName,
            body: body,
            selection: selection
        )
    }

    func setArtifactCommentResolved(_ commentID: String, resolved: Bool) async throws {
        try await storage.setArtifactCommentResolvedAndSync(commentID, resolved: resolved)
    }
}

/// What Move to Trash says about a page's subpages: the page menu's question,
/// in Codex's words (`codex.space.page.archive.description`: "This page and its
/// subpages will move to Trash. You can restore them from Trash."), and the
/// toast after.
enum PageTrashWording {
    static func message(subpageCount: Int) -> String {
        switch subpageCount {
        case 0: return "This page will move to Trash. You can restore it from Trash."
        case 1: return "This page and its subpage will move to Trash. You can restore them from Trash."
        default: return "This page and its \(subpageCount) subpages will move to Trash. You can restore them from Trash."
        }
    }

    static func toast(title: String, subpageCount: Int) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch subpageCount {
        case 0: return "Moved to Trash"
        case 1: return name.isEmpty ? "Moved the page and its subpage to Trash" : "Moved “\(name)” and its subpage to Trash"
        default: return name.isEmpty ? "Moved the page and its \(subpageCount) subpages to Trash" : "Moved “\(name)” and its \(subpageCount) subpages to Trash"
        }
    }
}
