import Foundation
import PDFKit

/// Reader highlights — the passages the learner marked and the notes they wrote
/// on them — over MCP.
///
/// The readers anchor a mark by its own words (`ReaderTextAnchor`), never by a
/// character offset alone, which is why an assistant can create one at all: it
/// supplies the passage, the anchor is measured against the source's canonical
/// text here, and every reader family resolves it the same way a mark made by
/// hand resolves. PDFs are no exception — a highlight with no page geometry is
/// re-anchored by `ReaderPDFHighlightSupport` from the quote when it paints.
/// A mark on a web page's picture (`ReaderImageAnchor`) is anchored to the
/// picture's URL instead, the way the Reader's Highlight pill anchors one, and
/// an assistant makes one by naming that URL.
///
/// A mark can also carry the chat its note came from (`chatSessionID`,
/// schema 139): research into what has changed since the source was written,
/// saved as a chat, is linked to the passage it updates, and the reader offers
/// that chat from the mark. From an in-app chat the link is that chat. And it
/// can carry the papers its note cites (`references`, schema 140), which the
/// reader lists on the mark with Add to Library or Open. The research itself
/// is the mark's `publication_update` (schema 141), kept apart from `note`,
/// which is always the learner's own.
extension MCPDataStore {

    /// Longest passage an assistant may mark. Well past a long paragraph, and
    /// short enough that a model cannot quietly highlight a whole chapter.
    static let maxHighlightQuoteCharacters = 4_000
    /// Longest note. The composer has no limit, but a note is an annotation
    /// rather than a document — an assistant with more to say should write it
    /// into the Notebook's notes instead.
    static let maxHighlightNoteCharacters = 8_000
    /// Longest since-publication update: the short version of a research
    /// chat, which holds the long one.
    static let maxHighlightUpdateCharacters = 4_000
    static let defaultHighlightSearchLimit = 50
    static let maxHighlightSearchLimit = 200

    // MARK: - Reading

    func listSourceHighlights(sourceID: String) throws -> String {
        let resolved = try resolvedHighlightSourceID(sourceID)
        let highlights = try knowledgeStore().sourceHighlights(sourceID: resolved.id)
        return try jsonString([
            "source_id": resolved.id,
            "title": resolved.title,
            "highlight_count": highlights.count,
            "highlights": highlights.map(highlightPayload),
            "guidance": highlights.isEmpty
                ? "The learner has not marked anything in this source yet. create_source_highlight marks a passage; quote it verbatim from get_source_content."
                : "A highlight's note is the learner's own words; an empty one is a bare mark they made while reading. A highlight's publication_update is what has been learned since the source was written, as research put it; update_source_highlight writes either, and research goes in publication_update, never in note. A highlight whose quote is empty and that carries pictures is a mark on a figure or image of the page. A highlight with a session_id carries the chat its note came from — often research into what has changed since the source was written; get_review_session_transcript reads it. A highlight's references are the papers its note cites; source_id marks the ones already in the library. follow_up true means the learner flagged the mark to follow up, whatever its color.",
        ] as [String: Any])
    }

    /// Every highlight in the library, newest first, optionally narrowed to
    /// marks whose passage or note mentions `query` and to one marker color.
    ///
    /// This is the "what have I been noting lately" question, which no
    /// per-source tool can answer: the learner asking it does not yet know
    /// which sources to look in. With `followUp` it is also "what did I flag
    /// to follow up", and with `color` "what do I doubt" (pink), across the
    /// library.
    func searchSourceHighlights(query queryText: String?, limit: Int?, color: String? = nil, followUp: Bool? = nil) throws -> String {
        // `query` names this type's SQL helper, so the caller-facing label keeps
        // its name while the body uses the renamed parameter.
        let trimmedQuery = (queryText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLimit = min(
            max(limit ?? Self.defaultHighlightSearchLimit, 1),
            Self.maxHighlightSearchLimit
        )
        let colorFilter = try validatedHighlightColor(color)
        let excludedSourceIDs = try knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true)

        var conditions: [String] = []
        var params: [Any] = []
        if !trimmedQuery.isEmpty {
            let pattern = "%" + Self.escapedLikePattern(trimmedQuery) + "%"
            conditions.append("""
                (h.text LIKE ? ESCAPE '\\' OR h.note LIKE ? ESCAPE '\\'
                   OR h.publication_update LIKE ? ESCAPE '\\')
                """)
            params += [pattern, pattern, pattern]
        }
        if let colorFilter {
            // A color written by a build with more colors reads as the default
            // here (`SourceHighlightColor(storedValue:)`), so it matches with it.
            if colorFilter == .default {
                let known = SourceHighlightColor.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
                conditions.append("(h.color = ? OR h.color IS NULL OR h.color NOT IN (\(known)))")
            } else {
                conditions.append("h.color = ?")
            }
            params.append(colorFilter.rawValue)
        }
        if let followUp {
            conditions.append(followUp ? "h.follow_up_at IS NOT NULL" : "h.follow_up_at IS NULL")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        params.append(resolvedLimit + excludedSourceIDs.count)

        let rows: [[String: Any]] = try withDB { db in
            try query(db, """
                SELECT h.highlight_id, h.source_id, h.text, h.note, h.color,
                       h.created_at, h.updated_at, h.page_index, h.quads_json,
                       h.chat_session_id, h.references_json, h.publication_update,
                       h.publication_update_at, h.follow_up_at, sp.title, sp.source_type
                FROM source_highlights h
                JOIN source_projection sp ON sp.id = h.source_id
                \(whereClause)
                ORDER BY h.created_at DESC, h.highlight_id
                LIMIT ?
            """, params: params)
        }

        // Sources the learner excluded from knowledge search and AI are excluded
        // here too: their notes are their content. Over-fetch by the exclusion
        // count above so filtering cannot silently return a short page.
        let visible = rows
            .filter { row in
                guard let sourceID = row["source_id"] as? String else { return false }
                return !excludedSourceIDs.contains(sourceID)
            }
            .prefix(resolvedLimit)

        return try jsonString([
            "query": trimmedQuery,
            "color": colorFilter?.rawValue ?? "",
            "follow_up": followUp.map { $0 as Any } ?? NSNull(),
            "highlight_count": visible.count,
            "highlights": visible.map(searchHighlightPayload),
            "guidance": "Ordered newest first. Call get_source_content with a source_id to read the passage in context, or list_source_highlights to see everything the learner marked in that source.",
        ] as [String: Any])
    }

    // MARK: - Writing

    /// The highlights and notes another app saved inside a PDF that arrived
    /// over MCP, brought in as the paper's own — the same pass the app's PDF
    /// import runs. Returns a sentence to append to the tool's answer, empty
    /// when the file carried none. The paper is in either way, so a failure
    /// here is reported rather than thrown.
    func importDocumentMarks(sourceID: String, pdfPath: String) -> String {
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return "" }
        let highlights = ReaderPDFHighlightSupport.importedHighlights(
            ReaderPDFHighlightSupport.embeddedMarks(in: document),
            sourceID: sourceID,
            in: document
        )
        guard !highlights.isEmpty else { return "" }
        do {
            let added = try knowledgeStore().insertImportedSourceHighlights(highlights)
            guard added > 0 else { return "" }
            let plural = added == 1 ? "" : "s"
            return " Brought in \(added) highlight\(plural) and note\(plural) saved in the PDF; list_source_highlights shows them."
        } catch {
            return " The highlights saved in the PDF were not brought in: \(error.localizedDescription)"
        }
    }

    /// Marks a passage in a source, optionally with a note on it.
    ///
    /// The quote is matched against the source's canonical text rather than
    /// trusted as given, and what gets stored is the document's own wording for
    /// the passage — otherwise a model's re-spaced or lightly paraphrased quote
    /// would save an anchor that no reader can ever find again.
    ///
    /// A picture is marked by `imageURL` instead of a quote — the URL of the
    /// `<img>` as the page serves it, which is what the Reader's own Highlight
    /// pill stores and what the reader re-finds the picture by. There is no
    /// canonical text to check a picture against, so the URL is taken as
    /// given; a quote and a picture together make one mark on both.
    ///
    /// `sessionID` links the chat the note came from; an in-app chat's own
    /// session (`hostSessionID`) is the link when none is named.
    func createSourceHighlight(
        sourceID: String,
        quote: String,
        note: String?,
        color: String?,
        imageURL: String? = nil,
        imageAlt: String? = nil,
        sessionID: String? = nil,
        hostSessionID: String? = nil,
        references rawReferences: Any? = nil,
        publicationUpdate: String? = nil
    ) throws -> String {
        let resolved = try resolvedHighlightSourceID(sourceID)
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAnchor = try validatedHighlightImage(url: imageURL, alt: imageAlt)
        let linkedChat = try validatedHighlightChat(sessionID) ?? resolvedHostSessionID(hostSessionID)
        let references = try validatedHighlightReferences(rawReferences) ?? []
        guard !trimmedQuote.isEmpty || imageAnchor != nil else {
            throw MCPError.invalidInput(
                "quote or image_url is required: pass the passage to mark, copied from the source text, or the URL of the page's picture to mark."
            )
        }
        guard trimmedQuote.count <= Self.maxHighlightQuoteCharacters else {
            throw MCPError.invalidInput(
                "quote must be \(Self.maxHighlightQuoteCharacters) characters or fewer. Mark the specific passage rather than a whole section."
            )
        }
        let resolvedNote = try validatedHighlightNote(note) ?? ""
        let resolvedUpdate = try validatedHighlightUpdate(publicationUpdate) ?? ""
        let resolvedColor = try validatedHighlightColor(color) ?? .default

        if trimmedQuote.isEmpty, let imageAnchor {
            return try createPictureHighlight(
                source: resolved,
                imageAnchor: imageAnchor,
                note: resolvedNote,
                color: resolvedColor,
                chatSessionID: linkedChat,
                references: references,
                publicationUpdate: resolvedUpdate
            )
        }

        guard let content = try knowledgeStore().loadSourceContent(resolved.id),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidInput(
                "Source \(resolved.id) has no stored text to anchor a highlight in. Call get_source_content first; a source whose text ForeverLM has not captured cannot carry reader notes."
            )
        }
        guard let range = ReaderTextAnchor(exact: trimmedQuote).resolve(in: content) else {
            throw MCPError.invalidInput(
                "That passage is not in '\(resolved.title)'. Copy the quote verbatim from get_source_content — differences in wording or punctuation prevent the reader from finding the passage again."
            )
        }

        let anchor = ReaderTextAnchor(text: content, range: range)
        if let existing = try knowledgeStore().sourceHighlights(sourceID: resolved.id).first(where: {
            ReaderTextAnchor.normalize($0.quote).text == ReaderTextAnchor.normalize(anchor.exact).text
        }) {
            throw MCPError.invalidInput(
                "That passage is already marked in '\(resolved.title)'. Use update_source_highlight with highlight_id \(existing.id) to change its note or color."
            )
        }

        let now = Date()
        var highlight = SourceHighlight(
            id: SourceHighlight.newID(),
            sourceID: resolved.id,
            quote: anchor.exact,
            note: resolvedNote,
            color: resolvedColor,
            anchor: anchor,
            // Page geometry belongs to a live PDFKit selection. A PDF reader
            // re-anchors a highlight without it from the quote when painting,
            // so leaving it off is correct rather than lossy.
            pdfAnchor: nil,
            imageAnchors: imageAnchor.map { [$0] } ?? [],
            chatSessionID: linkedChat,
            references: references,
            createdAt: now,
            updatedAt: now
        )
        highlight.setPublicationUpdate(resolvedUpdate, at: now)
        try knowledgeStore().saveSourceHighlight(highlight)

        return try jsonString([
            "status": "created",
            "source_id": resolved.id,
            "title": resolved.title,
            "highlight": highlightPayload(highlight),
            "guidance": linkedChat == nil
                ? "The mark is stored as the source's own wording for the passage, which is what the reader paints. It appears in ForeverLM's reader and notes list for this source."
                : "The mark is stored as the source's own wording for the passage, which is what the reader paints. It appears in ForeverLM's reader and notes list for this source, and the reader opens the linked chat from it.",
        ] as [String: Any])
    }

    /// A mark on a picture alone: no words, the picture's URL as the anchor.
    private func createPictureHighlight(
        source: (id: String, title: String),
        imageAnchor: ReaderImageAnchor,
        note: String,
        color: SourceHighlightColor,
        chatSessionID: String?,
        references: [SourceHighlightReference],
        publicationUpdate: String
    ) throws -> String {
        let existing = try knowledgeStore().sourceHighlights(sourceID: source.id)
        if let duplicate = existing.first(where: { $0.isPictureOnly && $0.imageAnchors.contains(where: { $0.src == imageAnchor.src }) }) {
            throw MCPError.invalidInput(
                "That picture is already marked in '\(source.title)'. Use update_source_highlight with highlight_id \(duplicate.id) to change its note or color."
            )
        }
        let now = Date()
        var highlight = SourceHighlight(
            id: SourceHighlight.newID(),
            sourceID: source.id,
            quote: "",
            note: note,
            color: color,
            anchor: ReaderTextAnchor(exact: ""),
            pdfAnchor: nil,
            imageAnchors: [imageAnchor],
            chatSessionID: chatSessionID,
            references: references,
            createdAt: now,
            updatedAt: now
        )
        highlight.setPublicationUpdate(publicationUpdate, at: now)
        try knowledgeStore().saveSourceHighlight(highlight)
        return try jsonString([
            "status": "created",
            "source_id": source.id,
            "title": source.title,
            "highlight": highlightPayload(highlight),
            "guidance": "The mark is anchored to the picture's URL, which is what the reader outlines. It appears in ForeverLM's reader and notes list for this source.",
        ] as [String: Any])
    }

    /// Revises the note, since-publication update, color, linked chat or cited
    /// papers on an existing mark. The passage itself is not editable: a
    /// different passage is a different mark. An empty `sessionID` unlinks the
    /// chat, an empty `references` list clears the papers and an empty
    /// `publicationUpdate` clears the update; nil leaves each as it is.
    func updateSourceHighlight(
        highlightID: String,
        note: String?,
        color: String?,
        sessionID: String? = nil,
        references rawReferences: Any? = nil,
        publicationUpdate: String? = nil,
        followUp: Bool? = nil
    ) throws -> String {
        let trimmedID = highlightID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("highlight_id is required. Use list_source_highlights to find it.")
        }
        let references = try validatedHighlightReferences(rawReferences)
        let update = try validatedHighlightUpdate(publicationUpdate)
        guard note != nil || color != nil || sessionID != nil || references != nil || update != nil || followUp != nil else {
            throw MCPError.invalidInput("Pass note, publication_update, color, follow_up, session_id or references. Nothing else about a highlight is editable.")
        }
        let store = try knowledgeStore()
        guard var highlight = try store.sourceHighlight(id: trimmedID) else {
            throw MCPError.notFound("Highlight not found: \(trimmedID). Use list_source_highlights to find the current IDs.")
        }
        // The source may have been excluded from AI since the mark was made.
        _ = try resolvedHighlightSourceID(highlight.sourceID)

        if let note {
            // An empty note is meaningful: it turns the mark back into a bare
            // highlight, which is what the composer does when the field is cleared.
            highlight.note = try validatedHighlightNote(note) ?? ""
        }
        if let color {
            guard let parsed = try validatedHighlightColor(color) else {
                throw MCPError.invalidInput("color cannot be empty. Allowed values: \(Self.highlightColorList).")
            }
            highlight.color = parsed
        }
        if let sessionID {
            // An empty session_id is meaningful too: it unlinks the chat and
            // leaves the note standing on its own.
            highlight.chatSessionID = try validatedHighlightChat(sessionID)
        }
        if let references {
            highlight.references = references
        }
        let now = Date()
        if let update {
            highlight.setPublicationUpdate(update, at: now)
        }
        if let followUp, followUp != highlight.isFlaggedForFollowUp {
            highlight.followUpAt = followUp ? now : nil
        }
        highlight.updatedAt = now
        try store.saveSourceHighlight(highlight)

        return try jsonString([
            "status": "updated",
            "source_id": highlight.sourceID,
            "highlight": highlightPayload(highlight),
        ] as [String: Any])
    }

    func deleteSourceHighlight(highlightID: String) throws -> String {
        let trimmedID = highlightID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("highlight_id is required. Use list_source_highlights to find it.")
        }
        let store = try knowledgeStore()
        guard let highlight = try store.sourceHighlight(id: trimmedID) else {
            throw MCPError.notFound("Highlight not found: \(trimmedID). Use list_source_highlights to find the current IDs.")
        }
        try store.deleteSourceHighlight(id: trimmedID)

        return try jsonString([
            "status": "deleted",
            "highlight_id": trimmedID,
            "source_id": highlight.sourceID,
            "quote": highlight.quote,
            "note": highlight.note,
        ] as [String: Any])
    }

    // MARK: - Shared

    static var highlightColorList: String {
        SourceHighlightColor.meaningGuide
    }

    /// Resolves a caller-supplied source token and refuses the sources the
    /// learner has kept away from AI, matching `get_source_content`.
    private func resolvedHighlightSourceID(_ sourceID: String) throws -> (id: String, title: String) {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("source_id is required.")
        }
        let store = try knowledgeStore()
        guard let resolvedID = try store.resolveSourceID(forLinkToken: trimmed) else {
            throw MCPError.notFound("Source not found: \(trimmed). Search the library again and use the returned source.")
        }
        let excludedSourceIDs = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        guard !KnowledgeStore.isBlockedFromOpening(resolvedID, excluded: excludedSourceIDs) else {
            throw MCPError.invalidInput(
                "Source is excluded from knowledge search and AI in ForeverLM Settings. Include its source family there before reading or marking it."
            )
        }
        let title: String = try withDB { db in
            let rows = try query(db, "SELECT title FROM source_projection WHERE id = ? LIMIT 1", params: [resolvedID])
            return rows.first?["title"] as? String ?? "Untitled"
        }
        return (resolvedID, title)
    }

    private func validatedHighlightNote(_ note: String?) throws -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxHighlightNoteCharacters else {
            throw MCPError.invalidInput(
                "note must be \(Self.maxHighlightNoteCharacters) characters or fewer. A longer write-up belongs in the Notebook's notes."
            )
        }
        return trimmed
    }

    private func validatedHighlightUpdate(_ update: String?) throws -> String? {
        guard let update else { return nil }
        let trimmed = update.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxHighlightUpdateCharacters else {
            throw MCPError.invalidInput(
                "publication_update must be \(Self.maxHighlightUpdateCharacters) characters or fewer. It is the short version; the research chat holds the long one."
            )
        }
        return trimmed
    }

    /// The picture a mark names, or nil when none was passed. Only an absolute
    /// `http(s):` URL can be re-found by the reader; anything else is refused.
    private func validatedHighlightImage(url: String?, alt: String?) throws -> ReaderImageAnchor? {
        guard let url else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parsed.host?.isEmpty == false else {
            throw MCPError.invalidInput(
                "image_url must be the absolute http(s) URL of a picture in the page, as the page serves it."
            )
        }
        return ReaderImageAnchor(src: trimmed, alt: alt ?? "")
    }

    /// The chat a `session_id` argument names, or nil when none was named.
    /// A chat link (`foreverlm://chat/<id>`) is accepted as its id; a chat
    /// that does not exist is refused rather than linked blind.
    private func validatedHighlightChat(_ sessionID: String?) throws -> String? {
        guard sessionID != nil else { return nil }
        let id = Self.reviewSessionID(from: sessionID)
        guard !id.isEmpty else { return nil }
        guard try reviewSessionExists(sessionID: id) else {
            throw MCPError.invalidInput(
                "No chat with ID \(id). Save the conversation first (import_review_chat returns its id), or find it with get_review_sessions."
            )
        }
        return id
    }

    /// The papers a `references` argument names, or nil when none was passed.
    /// Each needs a citation and a DOI or an http(s) address; one that has
    /// neither is refused rather than kept as a paper nobody can open, and a
    /// paper named twice is kept once.
    private func validatedHighlightReferences(_ raw: Any?) throws -> [SourceHighlightReference]? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let entries = raw as? [Any] else {
            throw MCPError.invalidInput("references must be a list of papers, each with a citation and a doi or url.")
        }
        guard entries.count <= SourceHighlightReference.maximumPerMark else {
            throw MCPError.invalidInput(
                "A highlight cites at most \(SourceHighlightReference.maximumPerMark) papers. Keep the ones the note names; the chat holds the rest."
            )
        }
        var references: [SourceHighlightReference] = []
        for (index, entry) in entries.enumerated() {
            guard let fields = entry as? [String: Any],
                  let reference = SourceHighlightReference.make(
                      citation: fields["citation"] as? String ?? "",
                      title: fields["title"] as? String,
                      url: fields["url"] as? String,
                      doi: fields["doi"] as? String
                  ) else {
                throw MCPError.invalidInput("references[\(index)] needs a citation and a doi or an http(s) url.")
            }
            if !references.contains(where: { $0.url == reference.url }) {
                references.append(reference)
            }
        }
        return references
    }

    /// One cited paper for the tool results, with the library source it names
    /// when the library holds it, so an assistant does not offer to add a paper
    /// the learner already has.
    private func highlightReferencePayload(_ reference: SourceHighlightReference, resolvingLibrary: Bool) -> [String: Any] {
        var entry: [String: Any] = ["citation": reference.citation, "url": reference.url]
        if !reference.title.isEmpty { entry["title"] = reference.title }
        if resolvingLibrary, let sourceID = (try? resolveAnimationSources([reference.url]))?.resolved.first {
            entry["source_id"] = sourceID
        }
        return entry
    }

    /// A linked chat's title, for the tool results; nil when the chat is gone.
    private func highlightChatTitle(_ sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        let rows = try? withDB { db in
            // A chat's title is its `topic` column (review_sessions has no
            // `title`), so reading `title` would give every mark a nil chat_title.
            try query(db, "SELECT topic FROM review_sessions WHERE id = ? LIMIT 1", params: [sessionID])
        }
        return rows?.first?["topic"] as? String
    }

    private func validatedHighlightColor(_ color: String?) throws -> SourceHighlightColor? {
        guard let color else { return nil }
        let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = SourceHighlightColor(rawValue: trimmed) else {
            throw MCPError.invalidInput("Unknown color '\(color)'. Allowed values: \(Self.highlightColorList).")
        }
        return parsed
    }

    private func highlightPayload(_ highlight: SourceHighlight) -> [String: Any] {
        var payload: [String: Any] = [
            "highlight_id": highlight.id,
            "quote": highlight.quote,
            "note": highlight.note,
            "color": highlight.color.rawValue,
            "color_meaning": highlight.color.meaning,
            "follow_up": highlight.isFlaggedForFollowUp,
            "created_at": KnowledgeStore.iso8601Formatter.string(from: highlight.createdAt),
            "updated_at": KnowledgeStore.iso8601Formatter.string(from: highlight.updatedAt),
        ]
        if let pdfAnchor = highlight.pdfAnchor {
            payload["page"] = pdfAnchor.pageIndex + 1
        }
        if !highlight.imageAnchors.isEmpty {
            payload["pictures"] = Self.picturePayload(highlight.imageAnchors)
        }
        if let chatID = highlight.linkedChatID {
            payload["session_id"] = chatID
            if let title = highlightChatTitle(chatID) { payload["chat_title"] = title }
        }
        if !highlight.references.isEmpty {
            payload["references"] = highlight.references.map {
                highlightReferencePayload($0, resolvingLibrary: true)
            }
        }
        if highlight.hasPublicationUpdate {
            payload["publication_update"] = highlight.publicationUpdate
            if let written = highlight.publicationUpdateAt {
                payload["publication_update_at"] = KnowledgeStore.iso8601Formatter.string(from: written)
            }
        }
        return payload
    }

    /// The pictures a mark is on, for the tool results.
    static func picturePayload(_ anchors: [ReaderImageAnchor]) -> [[String: Any]] {
        anchors.map { anchor in
            var entry: [String: Any] = ["url": anchor.src, "alt": anchor.alt]
            if anchor.width > 0, anchor.height > 0 {
                entry["width"] = anchor.width
                entry["height"] = anchor.height
            }
            return entry
        }
    }

    private func searchHighlightPayload(_ row: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = [
            "highlight_id": row["highlight_id"] as? String ?? "",
            "source_id": row["source_id"] as? String ?? "",
            "source_title": row["title"] as? String ?? "Untitled",
            "source_type": row["source_type"] as? String ?? "",
            "quote": row["text"] as? String ?? "",
            "note": row["note"] as? String ?? "",
            "color": SourceHighlightColor(storedValue: row["color"] as? String).rawValue,
            "color_meaning": SourceHighlightColor(storedValue: row["color"] as? String).meaning,
            "follow_up": row["follow_up_at"] != nil && !(row["follow_up_at"] is NSNull),
            "created_at": KnowledgeStore.iso8601Formatter.string(from: highlightDate(row["created_at"])),
            "updated_at": KnowledgeStore.iso8601Formatter.string(from: highlightDate(row["updated_at"])),
        ]
        // Page geometry is only ever present for PDFs, and `page_index` defaults
        // to 0 for every other reader, so the quads decide whether it means
        // anything.
        let quadsJSON = row["quads_json"] as? String ?? "[]"
        if let pageIndex = row["page_index"] as? Int,
           ReaderPDFAnchor(pageIndex: pageIndex, quadsJSON: quadsJSON) != nil {
            payload["page"] = pageIndex + 1
        }
        let pictures = ReaderImageAnchor.anchors(storedJSON: quadsJSON)
        if !pictures.isEmpty {
            payload["pictures"] = Self.picturePayload(pictures)
        }
        if let chatID = (row["chat_session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chatID.isEmpty {
            payload["session_id"] = chatID
        }
        // Listed without the library lookup: a search can return two hundred
        // marks, and list_source_highlights answers "is it in the library".
        let references = SourceHighlightReference.references(storedJSON: row["references_json"] as? String)
        if !references.isEmpty {
            payload["references"] = references.map { highlightReferencePayload($0, resolvingLibrary: false) }
        }
        if let update = (row["publication_update"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !update.isEmpty {
            payload["publication_update"] = update
            if row["publication_update_at"] != nil, !(row["publication_update_at"] is NSNull) {
                payload["publication_update_at"] = KnowledgeStore.iso8601Formatter.string(from: highlightDate(row["publication_update_at"]))
            }
        }
        return payload
    }

    /// Highlight timestamps are Unix epoch seconds, not the Apple epoch the
    /// older source tables use.
    private func highlightDate(_ value: Any?) -> Date {
        switch value {
        case let seconds as Double: return Date(timeIntervalSince1970: seconds)
        case let seconds as Int: return Date(timeIntervalSince1970: Double(seconds))
        default: return Date(timeIntervalSince1970: 0)
        }
    }
}
