import Foundation
import OSLog

/// The card the reader gets on one mark: its color, an optional comment, and
/// the way to remove it.
///
/// A mark is saved the instant the reader makes it, so this card never holds
/// unsaved work — it opens on a highlight that already exists and everything it
/// changes writes straight through. Marking a passage is the gesture;
/// commenting on it is optional and comes second.
struct ReaderHighlightCard: Identifiable, Equatable {
    let id = UUID()
    let sourceID: String
    let highlightID: String
    /// Opens with the comment field focused, ready to type into. The field is
    /// always showing; this says whether the reader came to write.
    var focusesComment: Bool
    /// Set on the card that follows a fresh mark: it retires itself when the
    /// reader carries on reading instead of reaching for it. A card opened by
    /// clicking a mark stays until it is closed.
    var retiresUntouched: Bool
    /// The mark's frame in screen coordinates, when the reader that opened
    /// the card could say where it is: the card hangs below it, clear of the
    /// words it is about. Nil when nothing on screen is the mark (a card
    /// opened from the notes list), and the card hangs off the pointer.
    var markOnScreen: CGRect? = nil
}

/// A side chat over words selected in the Reader: the popover a reply's side
/// chat is (`ChatReplySideChat`), hung off a passage in a source instead. It
/// stays until its X is clicked, and the next one replaces it.
struct ReaderSideChat: Identifiable {
    let sourceID: String
    /// The passage's frame in screen coordinates, when the reader could say
    /// where it is: the popover hangs off it. Nil hangs it off the pointer.
    let markOnScreen: CGRect?
    /// The window the words were selected in, so the same source open in
    /// another window does not raise a second popover over the same exchange.
    let windowNumber: Int?
    let model: ChatReplySideChatModel

    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

@MainActor
extension StudioViewModel {
    private static let readerNotesLogger = Logger(
        subsystem: "com.foreverlm.app",
        category: "ReaderNotes"
    )

    /// Highlights on a source, in the order the notes list shows them.
    func highlights(for sourceID: String) -> [SourceHighlight] {
        readerHighlights[sourceID] ?? []
    }

    func highlight(id: String, sourceID: String) -> SourceHighlight? {
        readerHighlights[sourceID]?.first { $0.id == id }
    }

    /// Loads a source's highlights into `readerHighlights` unless they are
    /// already there. Readers call this when they open a source; a miss costs
    /// one indexed query, a hit costs nothing.
    func loadReaderHighlightsIfNeeded(for sourceID: String) async {
        guard !sourceID.isEmpty, readerHighlights[sourceID] == nil else { return }
        await reloadReaderHighlights(for: sourceID)
    }

    func reloadReaderHighlights(for sourceID: String) async {
        guard !sourceID.isEmpty else { return }
        do {
            let highlights = try await storage.sourceHighlights(sourceID: sourceID)
            readerHighlights[sourceID] = highlights
        } catch {
            Self.readerNotesLogger.error(
                "Failed to load highlights for \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // An empty entry still marks the source as loaded, so a storage
            // fault does not turn into a query on every reader repaint.
            readerHighlights[sourceID] = []
        }
    }

    // MARK: Marking

    /// Marks the passage the reader just selected, and opens the card on it.
    ///
    /// The mark is written before the card appears: pressing Highlight is the
    /// whole gesture. A reader who types nothing, closes the card, or quits the
    /// app still keeps the highlight — there is no draft to lose.
    ///
    /// A web selection over pictures marks them too (`imageAnchors`); one
    /// over pictures alone has no words, and the anchor's empty passage with
    /// the context either side is what keeps its place in reading order.
    func highlightReaderSelection(
        sourceID: String,
        quote: String,
        anchor: ReaderTextAnchor,
        pdfAnchor: ReaderPDFAnchor?,
        imageAnchors: [ReaderImageAnchor] = [],
        markOnScreen: CGRect? = nil,
        color: SourceHighlightColor = .default,
        opensCard: Bool = true
    ) async {
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWords = !trimmedQuote.isEmpty && !anchor.isEmpty
        guard !sourceID.isEmpty, hasWords || !imageAnchors.isEmpty else {
            showToast("Select text or a picture in the reader first")
            return
        }
        let now = Date()
        let highlight = SourceHighlight(
            id: SourceHighlight.newID(),
            sourceID: sourceID,
            quote: hasWords ? trimmedQuote : "",
            note: "",
            color: color,
            anchor: anchor,
            pdfAnchor: pdfAnchor,
            imageAnchors: pdfAnchor == nil ? imageAnchors : [],
            createdAt: now,
            updatedAt: now
        )
        // Optimistic: the readers paint from `readerHighlights`, so the mark
        // has to land there before the round-trip rather than after it.
        applyLocally(highlight)
        // A mark made where the colour was already chosen (the words of a
        // citation card) needs no card to choose it again.
        if opensCard {
            readerHighlightCard = ReaderHighlightCard(
                sourceID: sourceID,
                highlightID: highlight.id,
                focusesComment: false,
                retiresUntouched: true,
                markOnScreen: markOnScreen
            )
        }

        do {
            try await storage.saveSourceHighlight(highlight)
        } catch {
            Self.readerNotesLogger.error(
                "Failed to save highlight \(highlight.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Take the paint back off rather than leave a mark that no longer
            // exists anywhere but this session.
            readerHighlights[sourceID]?.removeAll { $0.id == highlight.id }
            if readerHighlightCard?.highlightID == highlight.id {
                readerHighlightCard = nil
            }
            showToast("Could not save that highlight")
        }
    }

    /// Chats about a saved mark: its words, and its pictures fetched again
    /// from where the page had them.
    func requestChatAboutHighlight(_ highlight: SourceHighlight) {
        // A clip's picture is a region of the PDF, not a URL anything can
        // fetch: it is drawn from the page here and handed over as bytes.
        if ReaderClip.isClip(highlight) {
            Task {
                guard let dataURL = await knowledgeMapClipPicture(highlight), let anchor = highlight.imageAnchors.first else {
                    showToast("Could not draw that clip from its PDF")
                    return
                }
                requestReaderSelectionExplanation(
                    sourceID: highlight.sourceID,
                    selectedText: "",
                    images: [ReaderSelectionImage(src: anchor.src, alt: anchor.alt, width: anchor.width, height: anchor.height, dataURL: dataURL)]
                )
            }
            return
        }
        requestReaderSelectionExplanation(
            sourceID: highlight.sourceID,
            selectedText: highlight.quote,
            images: highlight.imageAnchors.map(ReaderSelectionImage.init(anchor:))
        )
    }

    // MARK: What's New

    /// What's New on a mark: what has been published since the source was
    /// written, researched in a Deep Research chat beside the reader, which
    /// links itself to the mark on its first send and writes the short version
    /// onto it as its since-publication update, beside the learner's own note
    /// (chat-design.md, "What's New"). A mark that already
    /// has its chat opens that chat rather than starting a second one.
    ///
    /// The mark turns blue unless the learner gave it a color of their own,
    /// so a chapter's updated passages stand out from its plain highlights.
    func requestResearchUpdate(for highlight: SourceHighlight) {
        if let chatID = highlight.linkedChatID {
            openLinkedChat(chatID)
            return
        }
        let passage = Self.cleanedReaderSelection(highlight.quote)
        guard SourceHighlight.hasWords(passage) else {
            showToast("What's New needs a passage with words in it")
            return
        }
        dismissReaderHighlightCard()
        if highlight.color == .default {
            Task { await setReaderNoteColor(.blue, highlightID: highlight.id, sourceID: highlight.sourceID) }
        }
        addSourceToContext(highlight.sourceID)
        revealChatBesideReader()
        readerSelectionExplanationRequest = ReaderSelectionExplanationRequest(
            sourceID: highlight.sourceID,
            selectedText: passage,
            researchUpdate: ReaderResearchUpdate(
                highlightID: highlight.id,
                sourceDescription: researchSourceDescription(for: highlight.sourceID)
            )
        )
    }

    /// Opens the chat a mark is linked to beside the reader.
    func openLinkedChat(_ sessionID: String) {
        revealChatBesideReader()
        requestResumeReviewSession(sessionID)
    }

    /// The chat a mark links to, when this Mac has it. Chats about the mark's
    /// source are indexed by source; one linked from elsewhere is looked up
    /// in the whole list.
    func linkedChat(for highlight: SourceHighlight) -> ReviewSessionRecord? {
        guard let chatID = highlight.linkedChatID else { return nil }
        return reviewSessionsBySourceID[highlight.sourceID]?.first { $0.id == chatID }
            ?? reviewSessionLinks.first { $0.id == chatID }
    }

    /// What a source is, in the words the research needs to know what counts
    /// as new: its title, and for a book chapter the book, its edition and
    /// author, as the library has them; for anything else its author, journal
    /// and year when known.
    func researchSourceDescription(for sourceID: String) -> String {
        guard let article = articlesById[sourceID] else { return "source \(sourceID)" }
        var parts = ["\"\(article.title)\""]
        if article.sourceType == .book,
           let group = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
           !group.isEmpty {
            var book = "a chapter of " + (bookTitles[group] ?? group)
            if let edition = bookDisplayEdition(group) { book += ", \(edition)" }
            if let author = bookDisplayAuthor(group) { book += ", by \(author)" }
            parts.append(book)
        } else {
            if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                parts.append("by \(author)")
            }
            if let journal = article.journal?.trimmingCharacters(in: .whitespacesAndNewlines), !journal.isEmpty {
                parts.append(journal)
            }
        }
        if let year = article.publishedYear?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
            parts.append("published \(year)")
        }
        return parts.joined(separator: ", ")
    }

    /// Opens the card on a mark that already exists — from clicking it in the
    /// page, or from the notes list.
    ///
    /// The comment field comes focused: a reader who reached for a mark either
    /// wants to read what they wrote or to write it, and the field shows the
    /// comment either way, so typing can start at once.
    ///
    /// `markOnScreen` is the clicked mark's frame in screen coordinates; the
    /// card hangs below it. The notes list has no mark on screen to give.
    func openReaderHighlight(highlightID: String, sourceID: String, markOnScreen: CGRect? = nil) {
        guard let highlight = highlight(id: highlightID, sourceID: sourceID) else { return }
        readerHighlightCard = ReaderHighlightCard(
            sourceID: sourceID,
            highlightID: highlight.id,
            focusesComment: true,
            retiresUntouched: false,
            markOnScreen: markOnScreen
        )
    }

    func dismissReaderHighlightCard() {
        readerHighlightCard = nil
    }

    // MARK: Side chat

    /// Side chat on the selection bar: a popover over the passage with a
    /// field, where the tutor answers about these words with the source's
    /// text in view (`Prompts.readerSideChat`). Nothing is saved, no chat
    /// starts and no row joins the rail. The field takes focus empty, so no
    /// model is spent until a question is typed; the source's text is read
    /// meanwhile, and the first answer waits for it rather than going without.
    ///
    /// A side chat already open closes first, and the new one opens on the
    /// next turn, as a reply's does: one popover closing while another opens
    /// in the same update can leave neither open.
    func openReaderSideChat(sourceID: String, passage: String, markOnScreen: CGRect?, windowNumber: Int?) {
        guard !sourceID.isEmpty,
              !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Select text in the reader first")
            return
        }
        let replacesOpen = readerSideChat.map { open in
            closeReaderSideChat(open)
            return true
        } ?? false
        let article = articlesById[sourceID]
        let storage = storage
        let sourceTextLoad = article.map { article in
            Task { await ReviewSessionManager.chatReadableText(for: article, storage: storage) }
        }
        let sideChat = ReaderSideChat(
            sourceID: sourceID,
            markOnScreen: markOnScreen,
            windowNumber: windowNumber,
            model: ChatReplySideChatModel(
                messageID: UUID(),
                anchor: nil,
                context: ChatReplySideChatContext(readerPassage: passage, sourceTitle: article?.title ?? ""),
                backend: LiveChatReplySideChatBackend(aiService: AIService()),
                sourceTextLoad: sourceTextLoad
            )
        )
        if replacesOpen {
            DispatchQueue.main.async { [weak self] in self?.readerSideChat = sideChat }
        } else {
            readerSideChat = sideChat
        }
    }

    /// The popover closed, by its X or by another taking its place. An answer
    /// still being written stops; the exchange is gone with it.
    func closeReaderSideChat(_ sideChat: ReaderSideChat) {
        guard readerSideChat?.id == sideChat.id else { return }
        sideChat.model.cancel()
        readerSideChat = nil
    }

    /// The side chat leaves for a new chat beside the Reader, with this
    /// source, the way the bar's Chat goes. An exchange travels as a side
    /// question does, its first line carrying the passage as a quote; a side
    /// chat with nothing said yet hands the passage over as Chat would have.
    func continueReaderSideChatInNewChat(_ sideChat: ReaderSideChat) {
        let model = sideChat.model
        let handoff = model.handoff(
            chatTitle: articlesById[sideChat.sourceID]?.title ?? "",
            openQuestion: nil,
            sourceIDs: [sideChat.sourceID],
            notebookID: nil
        )
        closeReaderSideChat(sideChat)
        guard let handoff else {
            requestReaderSelectionExplanation(sourceID: sideChat.sourceID, selectedText: model.context.passage)
            return
        }
        addSourceToContext(sideChat.sourceID)
        revealChatBesideReader()
        readerSelectionExplanationRequest = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        showToast(Self.addedToChatMessage("Side chat", elsewhere: chatRequestElsewhereNotice))
    }

    /// Attaches, rewrites or clears a mark's comment. A no-op when the text is
    /// unchanged, so a card that opens and closes untouched writes nothing.
    func setReaderNoteComment(
        _ comment: String,
        highlightID: String,
        sourceID: String
    ) async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var highlight = highlight(id: highlightID, sourceID: sourceID),
              highlight.note != trimmed else { return }
        let hadComment = highlight.hasNote
        highlight.note = trimmed
        highlight.updatedAt = Date()
        applyLocally(highlight)
        do {
            try await storage.saveSourceHighlight(highlight)
        } catch {
            Self.readerNotesLogger.error(
                "Failed to save comment on \(highlightID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await reloadReaderHighlights(for: sourceID)
            showToast("Could not save that comment")
            return
        }
        if !trimmed.isEmpty {
            showToast(hadComment ? "Comment saved" : "Comment added")
        }
    }

    func removeReaderHighlight(highlightID: String, sourceID: String) async {
        let removed = readerHighlights[sourceID]?.first { $0.id == highlightID }
        readerHighlights[sourceID]?.removeAll { $0.id == highlightID }
        followUpMarkStore = FollowUpList.removing(highlightID, from: followUpMarkStore)
        if readerHighlightCard?.highlightID == highlightID {
            readerHighlightCard = nil
        }

        do {
            try await storage.deleteSourceHighlight(id: highlightID)
        } catch {
            Self.readerNotesLogger.error(
                "Failed to delete highlight \(highlightID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            if let removed { applyLocally(removed) }
            showToast("Could not remove that highlight")
            return
        }
        // One message either way: the comment was part of the mark, and it
        // goes with it.
        showToast("Highlight removed")
    }

    /// Takes research's update off a mark, leaving the passage, the learner's
    /// note and the chat the update came from, which still holds it.
    func clearReaderPublicationUpdate(highlightID: String, sourceID: String) async {
        guard var highlight = highlight(id: highlightID, sourceID: sourceID),
              highlight.hasPublicationUpdate else { return }
        highlight.setPublicationUpdate("")
        highlight.updatedAt = Date()
        applyLocally(highlight)
        do {
            try await storage.saveSourceHighlight(highlight)
        } catch {
            Self.readerNotesLogger.error(
                "Failed to clear the update on \(highlightID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await reloadReaderHighlights(for: sourceID)
            showToast("Could not remove that update")
            return
        }
        showToast("Update removed")
    }

    /// Changes a mark's color. The card writes through on every press, so
    /// the swatches are the setting rather than a pending choice.
    func setReaderNoteColor(
        _ color: SourceHighlightColor,
        highlightID: String,
        sourceID: String
    ) async {
        guard var highlight = highlight(id: highlightID, sourceID: sourceID),
              highlight.color != color else { return }
        highlight.color = color
        highlight.updatedAt = Date()
        applyLocally(highlight)
        do {
            try await storage.saveSourceHighlight(highlight)
        } catch {
            await reloadReaderHighlights(for: sourceID)
        }
    }

    /// Inserts or replaces a highlight in the in-memory cache, keeping the
    /// oldest-first order storage reads back.
    func applyLocally(_ highlight: SourceHighlight) {
        var highlights = readerHighlights[highlight.sourceID] ?? []
        if let index = highlights.firstIndex(where: { $0.id == highlight.id }) {
            highlights[index] = highlight
        } else {
            highlights.append(highlight)
        }
        highlights.sort {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        readerHighlights[highlight.sourceID] = highlights
        if followUpMarksLoaded {
            followUpMarkStore = FollowUpList.applying(highlight, to: followUpMarkStore)
        }
    }
}
