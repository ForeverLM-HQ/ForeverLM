import Foundation

// The member's highlights on the phone (docs/cloudkit-schema-design.md §3.5.17, D18): one Highlight
// record per mark in `Library`, written as the web's writer writes it (`saveSourceHighlight`) and read
// in the shape the Mac's `HighlightProjection` writes:
// the locator `{t: "pdf", page, quads}` for a PDF mark, else `{t: "text"}`, both with the text anchor
// (`offset`, `len`, `quote`, `prefix`, `suffix`) and a mark on pictures with its `images`; `refs` the cited
// references and the since-publication update. A highlight is never taken by its source going (D18).

/// A highlight's `locator` and `refs` both ways.
enum MobileHighlightLocator {
    static func locator(_ highlight: SourceHighlight) -> SyncJSON {
        let exact = highlight.anchor.exact.isEmpty ? highlight.quote : highlight.anchor.exact
        var locator: [String: SyncJSON] = [
            "offset": SyncJSON(Int64(max(highlight.anchor.offset, 0))),
            "len": SyncJSON(Int64(exact.utf16.count)),
            "quote": .string(exact),
            "prefix": .string(highlight.anchor.prefix),
            "suffix": .string(highlight.anchor.suffix),
        ]
        if let pdf = highlight.pdfAnchor {
            locator["t"] = .string("pdf")
            locator["page"] = SyncJSON(Int64(pdf.pageIndex))
            locator["quads"] = json(pdf.quads) ?? .array([])
        } else {
            locator["t"] = .string("text")
            if !highlight.imageAnchors.isEmpty, let images = json(highlight.imageAnchors) { locator["images"] = images }
        }
        return .object(locator)
    }

    /// The cited references, the update and the follow-up flag, or null when the mark has none of them.
    static func refs(_ highlight: SourceHighlight) -> SyncJSON {
        var refs: [String: SyncJSON] = [:]
        if !highlight.references.isEmpty, let references = json(highlight.references) { refs["references"] = references }
        if highlight.hasPublicationUpdate {
            refs["publicationUpdate"] = .string(highlight.publicationUpdate)
            if let at = highlight.publicationUpdateAt { refs["publicationUpdateAt"] = SyncJSON(SyncTime.milliseconds(at)) }
        }
        if let at = highlight.followUpAt { refs["followUpAt"] = SyncJSON(SyncTime.milliseconds(at)) }
        return refs.isEmpty ? .null : .object(refs)
    }

    /// A mark as the Reader takes it, from what a Highlight record holds.
    static func highlight(id: String, sourceID: String, text: String?, color: String?, note: String?, chatID: String?, locator: SyncJSON?,
                          refs: SyncJSON?, createdAt: Date, editedAt: Date?) -> SourceHighlight {
        let quote = text ?? locator?["quote"]?.stringValue ?? ""
        let anchor = ReaderTextAnchor(exact: locator?["quote"]?.stringValue ?? quote, prefix: locator?["prefix"]?.stringValue ?? "",
                                      suffix: locator?["suffix"]?.stringValue ?? "", offset: Int(locator?["offset"]?.int64Value ?? 0))
        var pdfAnchor: ReaderPDFAnchor?
        var images: [ReaderImageAnchor] = []
        if locator?["t"]?.stringValue == "pdf", let quads = locator?["quads"], quads != .null {
            pdfAnchor = ReaderPDFAnchor(pageIndex: Int(locator?["page"]?.int64Value ?? 0), quadsJSON: String(decoding: quads.serialized(), as: UTF8.self))
        } else {
            images = decode([ReaderImageAnchor].self, locator?["images"]) ?? []
        }
        var highlight = SourceHighlight(
            id: id, sourceID: sourceID, quote: quote, note: note ?? "", color: SourceHighlightColor(storedValue: color), anchor: anchor,
            pdfAnchor: pdfAnchor, imageAnchors: images, chatSessionID: chatID.flatMap { $0.isEmpty ? nil : $0 },
            references: decode([SourceHighlightReference].self, refs?["references"]) ?? [],
            createdAt: createdAt, updatedAt: editedAt ?? createdAt
        )
        if let update = refs?["publicationUpdate"]?.stringValue, !update.isEmpty {
            highlight.publicationUpdate = update
            highlight.publicationUpdateAt = refs?["publicationUpdateAt"]?.int64Value.map(SyncTime.date(milliseconds:))
        }
        highlight.followUpAt = refs?["followUpAt"]?.int64Value.map(SyncTime.date(milliseconds:))
        return highlight
    }

    private static func json<T: Encodable>(_ value: T) -> SyncJSON? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { try? SyncJSON(parsing: $0) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: SyncJSON?) -> T? {
        guard let value, value != .null else { return nil }
        return try? JSONDecoder().decode(type, from: value.serialized())
    }
}

extension MobileReadModels {
    /// The member's highlights, from the index alone, oldest first.
    static func highlights(in connection: SQLiteConnection) throws -> [SourceHighlight] {
        var highlights: [SourceHighlight] = []
        try connection.query("""
            SELECT id, source_id, text, color, note, chat_id, locator_json, refs_json, created_at, edited_at FROM m_highlights
            WHERE zone_key = ? AND source_id IS NOT NULL ORDER BY created_at, id
        """, [.text(libraryKey)]) { row in
            guard let id = row.text(0), let sourceID = row.text(1) else { return }
            let parse: (String?) -> SyncJSON? = { $0.flatMap { try? SyncJSON(parsing: Data($0.utf8)) } }
            highlights.append(MobileHighlightLocator.highlight(
                id: id, sourceID: sourceID, text: row.text(2), color: row.text(3), note: row.text(4), chatID: row.text(5),
                locator: parse(row.text(6)), refs: parse(row.text(7)), createdAt: date(row.integer(8)) ?? .distantPast, editedAt: date(row.integer(9))
            ))
        }
        return highlights
    }
}

extension MobileWrite {
    /// A highlight made or edited (the web's `saveSourceHighlight`): its source, quote and creation are
    /// written once (S); its locator, colour, note, chat and references move with each edit.
    mutating func saveHighlight(_ highlight: SourceHighlight) throws {
        let id = highlight.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = highlight.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !quote.isEmpty || !highlight.imageAnchors.isEmpty else { throw MobileRecordWriterError.refused("Select text to highlight.") }
        var patch = RecordPatch(.highlight, id: id)
        let current = try held(.highlight, id, in: Self.libraryKey)
        if current == nil {
            patch.changes["sourceID"] = .value(.string(highlight.sourceID))
            patch.changes["text"] = .value(.string(quote))
            patch.changes["createdAt"] = .value(SyncJSON(SyncTime.milliseconds(highlight.createdAt)))
        }
        patch.changes["locator"] = .value(MobileHighlightLocator.locator(highlight))
        patch.changes["color"] = .value(.string(highlight.color.rawValue))
        // A note spilled above 32 KiB reads as empty (no satellite fetch for highlights yet), and the Reader sends
        // back what it read: an empty note over a spilled one is the note it could not read, not one the
        // learner cleared, so the edit of a colour or a link leaves the note alone.
        let holdsSpilledNote = current?.fields["note"].map { SyncEnvelope.spilledFile($0) != nil } ?? false
        if !(holdsSpilledNote && highlight.note.isEmpty) {
            patch.changes["note"] = .value(.string(highlight.note))
        }
        patch.changes["chatID"] = .value(highlight.linkedChatID.map(SyncJSON.string) ?? .null)
        patch.changes["refs"] = .value(MobileHighlightLocator.refs(highlight))
        try write(patch, in: Self.libraryKey)
    }

    mutating func deleteHighlight(_ id: String) throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, try held(.highlight, id, in: Self.libraryKey) != nil else { return }
        try delete(.highlight, id, in: Self.libraryKey)
    }
}
