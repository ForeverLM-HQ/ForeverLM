// Part of ReviewSessionManager: attached context, images and video moments.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    func addContextSources(_ articles: [StudioArticle]) async {
        var seenIDs: Set<String> = []
        let requestedArticles = articles.filter { article in
            seenIDs.insert(article.id).inserted
        }
        let articlesToLoad = requestedArticles.filter { !loadedSourceIDs.contains($0.id) }
        let newArticles = requestedArticles.filter { !activeSourceIDs.contains($0.id) }
        guard !articlesToLoad.isEmpty else { return }

        isSearching = true
        await refreshSourceContextBudgetFromSelectedModel()
        let requestedContext = await loadSourceContext(from: articlesToLoad)

        guard !requestedContext.readableSourceIDs.isEmpty else {
            isSearching = false
            errorMessage = "No readable source content is available for the dropped source."
            return
        }
        if !newArticles.isEmpty {
            let newContext = await loadSourceContext(from: newArticles)
            let freshSources = newContext.sources.filter { !activeSourceIDs.contains($0.id) }
            activeSourceIDs.append(contentsOf: freshSources.map(\.id))
            activeArticles.append(contentsOf: newArticles)

            let refreshedContext = await loadSourceContext(from: activeArticles)
            foundSources = refreshedContext.sources
            sourceManifest = refreshedContext.manifest
        }

        // Dropping a source into a chat is an explicit request to work with it,
        // so it loads in full — even when it was already attached through a
        // Notebook pool. The pool itself stays catalog-only.
        // Appended rather than rebuilt so text loaded earlier in the session
        // survives and stays byte-identical for the cache.
        let dropped = await loadSourceTextBlock(
            for: articlesToLoad,
            budget: max(0, sourceContextCharacterLimit - sourceContext.count)
        )
        isSearching = false
        appendLoadedSourceText(dropped)
        recordContextAdditions(articlesToLoad.filter { dropped.loadedIDs.contains($0.id) })

        if let sessionID {
            do {
                try await storage.updateReviewSessionSources(sessionID: sessionID, sourceIDs: persistedSessionSourceIDs)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to update in-app review session sources: \(error.localizedDescription)")
            }
            await persistLoadedSourceIDs()
            // A source brought into a chat that then holds only it is a chat
            // day for it, the way session creation records one for the single
            // source a chat opens on. Sources dropped in beside others are
            // context until a reply cites them (`recordCitedSourceChatActivity`).
            if activeSourceIDs.count == 1, let only = newArticles.first(where: { $0.id == activeSourceIDs[0] }) {
                do {
                    _ = try await storage.recordScheduledSourceActivity(sourceID: only.id, on: Date(), kind: .chat)
                } catch {
                    logger.error("Failed to log chat activity for \(only.id, privacy: .public): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Attach a Doc to this chat, or refresh one already attached to the
    /// revision it now carries.
    ///
    /// Additive, like dropping a source in: it never displaces what the
    /// conversation is already holding. The Docs *selection* handoff is the
    /// opposite gesture — "chat about exactly this passage" — and clears the
    /// idle pool through `clearStagedSources`.
    func addContextDoc(_ doc: ChatDocAttachment) {
        if let index = contextDocs.firstIndex(where: { $0.id == doc.id }) {
            guard contextDocs[index] != doc else { return }
            contextDocs[index] = doc
        } else {
            contextDocs.append(doc)
        }
    }

    func removeContextDoc(_ artifactID: String) {
        contextDocs.removeAll { $0.id == artifactID }
    }

    // MARK: - The canvas as context

    /// Gives this chat cards of canvas `canvasID`: they follow the cards it
    /// holds from that canvas, or (`replacing`, or when it held cards of
    /// another canvas) are all it holds from now on. Returns how many were
    /// left out because a chat holds at most
    /// `KnowledgeMapChatContext.cardLimit`.
    ///
    /// Only the chips and the prompt hold the cards; the text of a source or a
    /// Doc among them is brought in through `addContextSources` and
    /// `addContextDoc`, which the chat pane calls beside this.
    @discardableResult
    func addCanvasCards(canvasID: String, name: String, cards: [KnowledgeMapChatCard], replacing: Bool) -> Int {
        var context = KnowledgeMapChatContext(canvasID: canvasID, name: name, cards: [])
        if !replacing, let held = canvasContext, held.canvasID == canvasID {
            context = held
            context.name = name
        }
        let leftOut = context.add(cards)
        canvasContext = context
        return leftOut
    }

    /// Takes a card out of the next turn's prompt. A source or a Doc it
    /// brought in stays attached until it is removed as any is.
    func removeCanvasCard(_ ref: String) {
        canvasContext?.remove(ref)
    }

    /// Drops the canvas and every card of it from this chat.
    func removeCanvasContext() {
        canvasContext = nil
    }

    // MARK: - Attached pictures

    /// Holds a dropped or pasted picture for the next message. Staged in the
    /// store at once so the composer's thumbnail and, after the send, the
    /// bubble resolve it without waiting on the disk.
    func attachImage(_ attachment: ChatImageAttachment) {
        guard !pendingImages.contains(where: { $0.id == attachment.id }) else { return }
        AttachedImageStore.stage(attachment.image, id: attachment.id)
        pendingImages.append(attachment)
    }

    func removePendingImage(_ id: String) {
        guard pendingImages.contains(where: { $0.id == id }) else { return }
        pendingImages.removeAll { $0.id == id }
        AttachedImageStore.unstage(id: id)
    }

    func discardPendingImages() {
        for attachment in pendingImages {
            AttachedImageStore.unstage(id: attachment.id)
        }
        pendingImages = []
    }

    /// The message as it leaves the composer: what the learner typed, then one
    /// image line per pending picture. The tray empties here, and each
    /// picture's bytes are written to this device's store off the main actor.
    /// A failed write is logged, not surfaced: the picture is already staged
    /// in memory, so this session's turns still carry it, and only a relaunch
    /// would show it as not on this device.
    ///
    /// Synchronous on purpose. The optimistic bubble has to go up in the same
    /// main-actor turn as the submit, and the content it shows is this string.
    func outgoingMessageContent(text: String) -> String {
        let attachments = pendingImages
        pendingImages = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmed }

        let logger = logger
        for attachment in attachments {
            let image = attachment.image
            let id = attachment.id
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try AttachedImageStore.write(image, id: id)
                } catch {
                    logger.error("Failed to store an attached picture \(id, privacy: .public): \(error.localizedDescription)")
                }
            }
        }
        let lines = attachments.compactMap { attachment in
            AttachedImageReference(id: attachment.id)?.markdown(alt: attachment.name)
        }
        return ([trimmed] + lines).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The learner's turn for the provider. Attached pictures, and the frame
    /// of a video moment the question was asked at (`VideoMomentFrames`),
    /// become image parts and their lines leave the text; a picture this
    /// device does not hold, or that the selected model cannot read, is named
    /// in the text instead, so the model knows a picture was there rather than
    /// seeing a bare reference or nothing at all.
    nonisolated static func userTurn(
        content: String,
        imagesReadable: Bool = true,
        imageForID: (String) -> AttachedImage? = { AttachedImageStore.cached(id: $0) },
        momentFrame: (SourceImageReference) -> AttachedImage? = { VideoMomentFrames.cached($0) }
    ) -> AIChatTurn {
        let moments = VideoMomentFrames.split(content)
        let split = AttachedImageReference.split(moments.text)
        guard !split.images.isEmpty || !moments.frames.isEmpty else { return .user(content) }
        var images: [AIChatImage] = []
        var notes: [String] = []
        for occurrence in split.images {
            guard imagesReadable else {
                notes.append("[Attached image \u{201C}\(occurrence.alt)\u{201D}: the selected model reads text only and cannot see it]")
                continue
            }
            if let image = imageForID(occurrence.reference.id) {
                images.append(AIChatImage(data: image.data, mediaType: image.mediaType))
            } else {
                notes.append("[Attached image \u{201C}\(occurrence.alt)\u{201D} is not available on this device]")
            }
        }
        for occurrence in moments.frames {
            guard imagesReadable else {
                notes.append("[Frame \u{201C}\(occurrence.alt)\u{201D}: the selected model reads text only and cannot see it]")
                continue
            }
            if let image = momentFrame(occurrence.reference) {
                images.append(AIChatImage(data: image.data, mediaType: image.mediaType))
            } else {
                notes.append("[Frame \u{201C}\(occurrence.alt)\u{201D} is not available on this device]")
            }
        }
        let text = ([split.text] + notes).filter { !$0.isEmpty }.joined(separator: "\n")
        return .user(text, images: images)
    }

    /// Provider messages for a route that takes text only, with each picture
    /// line replaced by a note saying so.
    nonisolated static func textOnlyProviderMessages(
        _ messages: [(role: String, content: String)]
    ) -> [(role: String, content: String)] {
        messages.map { message in
            guard message.role == "user" else { return message }
            let attached = AttachedImageReference.textOnly(message.content) { occurrence in
                "[Attached image \u{201C}\(occurrence.alt)\u{201D}: this route sends text only and cannot show it]"
            }
            let content = VideoMomentFrames.textOnly(attached) { occurrence in
                "[Frame \u{201C}\(occurrence.alt)\u{201D}: this route sends text only and cannot show it]"
            }
            return (role: message.role, content: content)
        }
    }

    /// Nil unless the message about to be sent carries a picture and the
    /// selected model is known to read text only. An unknown capability is not
    /// a refusal: the request goes out and the provider's own answer surfaces.
    nonisolated static func visionRefusal(for config: AITaskConfig, latestUserMessage: String?) -> String? {
        guard let latestUserMessage, AttachedImageReference.containsReference(latestUserMessage) else { return nil }
        guard KeychainService.modelSupportsVision(provider: config.provider, model: config.model) == false else { return nil }
        return "\(config.model) reads text only, so it cannot see the picture you attached. Choose a model that reads images from the model menu and retry."
    }

    func removeContextSource(_ sourceID: String, availableArticles: [StudioArticle]) async {
        guard activeSourceIDs.contains(sourceID) else { return }

        let remainingIDs = activeSourceIDs.filter { $0 != sourceID }
        activeSourceIDs = remainingIDs

        let remainingArticles = remainingIDs.compactMap { id in
            availableArticles.first { $0.id == id }
        }
        activeArticles = remainingArticles

        isSearching = true
        let context = await loadSourceContext(from: remainingArticles)
        foundSources = context.sources
        sourceManifest = context.manifest

        // Rebuild the loaded text from what survives, so the prompt stops
        // claiming a source the learner just detached. Removal is rare and
        // deliberate, so the cache miss it costs is the right trade.
        await refreshSourceContextBudgetFromSelectedModel()
        let reloaded = await loadSourceTextBlock(
            for: remainingArticles.filter { loadedSourceIDs.contains($0.id) },
            budget: sourceContextCharacterLimit
        )
        isSearching = false
        sourceContext = reloaded.text
        perSourcePromptShares = reloaded.shares
        loadedSourceIDs = reloaded.loadedIDs
        // Detached before a message was sent: there is nothing to say it was added.
        pendingContextAdditions.removeAll { $0.id == sourceID }

        if let sessionID {
            do {
                try await storage.updateReviewSessionSources(sessionID: sessionID, sourceIDs: persistedSessionSourceIDs)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to update in-app review session sources: \(error.localizedDescription)")
            }
            await persistLoadedSourceIDs()
        }
    }

    // MARK: - Sources added mid-conversation

    /// Notes sources the learner just brought in, once a conversation exists to
    /// note them against. Staging before the first message is not an addition:
    /// those sources are what the chat opens on.
    private func recordContextAdditions(_ articles: [StudioArticle]) {
        guard sessionActive || sessionID != nil || !chatMessages.isEmpty else { return }
        let pending = Set(pendingContextAdditions.map(\.id))
        for article in articles where !pending.contains(article.id) {
            pendingContextAdditions.append(ChatContextAdditions.Source(
                id: article.id,
                title: article.title,
                type: article.sourceType.rawValue
            ))
        }
    }

    /// The stored context for the message about to be sent: the pending
    /// additions as a mark above whatever the message carried anyway, and the
    /// pending list emptied — they belong to this message now.
    func attachPendingContextAdditions(to contextualContent: String?) -> String? {
        var contextualContent = contextualContent
        if !pendingMemoryReviewNotes.isEmpty {
            let notes = pendingMemoryReviewNotes.joined(separator: "\n")
            pendingMemoryReviewNotes = []
            contextualContent = [notes, contextualContent].compactMap { $0 }.joined(separator: "\n\n")
        }
        guard !pendingContextAdditions.isEmpty else { return contextualContent }
        let added = pendingContextAdditions
        pendingContextAdditions = []
        pendingMemoryReviewNotes = []
        return ChatContextAdditions.contextContent(added: added, referenceContext: contextualContent)
    }

    /// The stored context for the message about to be sent, with what every
    /// window has on screen written into its mark: the sources
    /// (`ChatContextAdditions.onScreen`), the card, and the Pages, Sites, web
    /// pages and courses (`ChatContextAdditions.OpenItem`). A chat
    /// outside a Studio window, or windows showing none of it, leaves the
    /// context as it was.
    func attachOnScreenSources(to contextualContent: String?) -> String? {
        guard let panes = openPanesForThisChat() else { return contextualContent }
        return ChatContextAdditions.contextContent(
            contextualContent,
            onScreen: panes.sourcesOnScreen,
            card: panes.cardOnScreen,
            open: panes.openOnScreen
        )
    }

    /// How long a send waits for the frame of its moment before it goes
    /// without one. Capturing reads YouTube's stream and usually lands in a
    /// second or two, and the first keystroke of the question started it.
    nonisolated static let videoMomentFrameWait: Duration = .seconds(8)

    /// The composer's text changed. The first words of a new message, beside
    /// a playing video this chat is about, pause the video — the question is
    /// about the moment the learner stopped at, not one it plays on to while
    /// they type — and start capturing the frame on screen there, for the
    /// send to hand the tutor.
    func composerTextChanged(_ text: String) {
        let holdsWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        defer { composerHoldsWords = holdsWords }
        guard holdsWords, !composerHoldsWords,
              let onScreen = openPanesForThisChat()?.sourcesOnScreen else { return }
        questionStartMoments = [:]
        for shown in onScreen where isVideoMomentForThisChat(shown) {
            guard let moment = shown.moment else { continue }
            if moment.playing == true { videoPauser?(shown.id) }
            questionStartMoments[shown.id] = moment.at
            startVideoMomentFrameCapture(sourceID: shown.id, seconds: moment.at)
        }
    }

    /// Whether a video on screen is one this chat's questions are about: one
    /// of its sources, or — before the chat has a conversation — any video
    /// beside it, since a question typed into a new chat next to a talk is
    /// about the talk. `openingArticles` are the sources a first message
    /// starts the chat with. A chat about something else still records where
    /// the video stood, and the tutor can look at it on request.
    func isVideoMomentForThisChat(
        _ shown: ChatContextAdditions.OnScreen,
        openingArticles: [StudioArticle]? = nil
    ) -> Bool {
        guard shown.moment != nil else { return false }
        if activeSourceIDs.contains(shown.id) { return true }
        if let openingArticles {
            return openingArticles.isEmpty || openingArticles.contains { $0.id == shown.id }
        }
        return sessionID == nil && !chatMessages.contains { $0.role == .assistant }
    }

    /// Starts capturing the frame at `seconds` of a video unless a capture of
    /// it is under way or done. The frame goes into `VideoMomentFrames` for
    /// the turns that send it, and its file stays for `show_source_image`.
    func startVideoMomentFrameCapture(sourceID: String, seconds: Int) {
        let reference = SourceImageReference(sourceID: sourceID, location: .moment(seconds))
        let key = reference.urlString
        guard videoMomentFrameCaptures[key] == nil else { return }
        let storage = storage
        let logger = logger
        videoMomentFrameCaptures[key] = Task { [weak self] in
            guard let article = await self?.librarySourceArticle(forRequestedID: sourceID) else { return false }
            do {
                try await Self.ensureVideoMoment(article: article, seconds: seconds, storage: storage)
            } catch {
                logger.warning("Couldn't capture the frame at \(seconds)s of \(sourceID, privacy: .public) for a question: \(error.localizedDescription)")
                self?.videoMomentFrameCaptures[key] = nil
                return false
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                SourceImageCatalog.renderMoment(reference)
            }.value
            guard let rendered else {
                self?.videoMomentFrameCaptures[key] = nil
                return false
            }
            VideoMomentFrames.stage(AttachedImage(data: rendered.data, mediaType: rendered.mediaType), for: reference)
            return true
        }
    }

    /// The Notebook this chat is filed under changed while it was open — moved
    /// from the sidebar or over MCP, or unlinked above the composer. The scope
    /// follows without a reopen, so the next turn carries the Notebook's
    /// guidance and pins its tool arguments the way a chat opened under it
    /// would. What the chat holds is untouched: where a chat is filed says
    /// nothing about what it is reading.
    func setNotebookScope(_ notebookID: String?) {
        notebookSourceScopeID = Self.nonEmptyTrimmed(notebookID)
    }

    /// Write the loaded set beside the saved chat so a reopen restores it
    /// (`resumeSession`). Called wherever `loadedSourceIDs` changes for a chat
    /// that has a row; a chat's first set is written when its row is created.
    /// Ending a session clears the in-memory set without calling this, so the
    /// record keeps what the chat held.
    func persistLoadedSourceIDs() async {
        guard let sessionID else { return }
        // Catalog order, then anything loaded from outside the catalog.
        let ordered = activeSourceIDs.filter { loadedSourceIDs.contains($0) }
            + loadedSourceIDs.subtracting(activeSourceIDs).sorted()
        do {
            try await storage.updateReviewSessionLoadedSources(sessionID: sessionID, sourceIDs: ordered)
        } catch {
            logger.error("Failed to remember a chat's loaded sources: \(error.localizedDescription)")
        }
    }

    /// Fold newly loaded source text into the session's context.
    ///
    /// Appends for the same reason `appendRetrievedSourceContext` trims from
    /// the tail: everything already in the block stays byte-identical, so the
    /// cached prefix still hits and only the new text is a cache write. This
    /// is what makes lazy loading cheaper than stuffing rather than more
    /// expensive — a source is paid for once, on the turn it is first read.
    private func appendLoadedSourceText(_ loaded: LoadedSourceText) {
        guard !loaded.isEmpty else { return }
        appendRetrievedSourceContext(loaded.text)
        perSourcePromptShares.append(contentsOf: loaded.shares)
        loadedSourceIDs.formUnion(loaded.loadedIDs)
    }
}
