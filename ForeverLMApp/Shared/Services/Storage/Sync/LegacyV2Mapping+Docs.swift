import Foundation

// MARK: - Docs and their comments (docs/cloudkit-schema-design.md §10, the `Artifact` and `ArtifactComment` rows)

extension LegacyV2Mapping {
    /// The Artifact fields an old Artifact record does not give: a Doc's `files` are laid out from the
    /// body package by the publisher, as the activation leaves them, so the record never clears them.
    static let artifactFieldsNotGiven: Set<String> = ["files"]

    /// An old Artifact: its Artifact, its body the package in `payloadAsset` (R5-2), laid out as the
    /// publisher lays it out, so its FileRef's hash is the old `bodyRevision`; the body hashes by that
    /// revision whether or not the package was fetched (an unchanged Doc's never is). A source's draft
    /// deck (`carddeck-*`) gives no Artifact (generation 2 retires decks) but its cards' draft Cards
    /// (`cardDeckDrafts`).
    static func mapArtifact(_ payload: CloudKitArtifactPayload, record: LegacyRecord, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        let artifact = payload.artifact
        guard !ArtifactBody.isCardDeck(id: artifact.id, kind: artifact.kind?.rawValue) else {
            mapping.records += try cardDeckDrafts(payload, record: record, context: context)
            return
        }
        let id = try context.wireID(.artifact, oldID: artifact.id, teamID: record.teamID)
        let decoded = try record.bodyPackage.map { try ArtifactBodyPackage.decode($0, expectedRevision: payload.bodyRevision) }
        let hasSite = try decoded.map { $0.siteFiles != nil } ?? context.hasLocalSite(artifact.id)
        let columns: [String: SQLiteValue] = [
            "title": .text(artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)), "home_notebook_id": .text(artifact.homeNotebookID),
            "is_draft": .integer(artifact.isDraft ? 1 : 0), "linked_url": .text(artifact.linkedURL),
            "created_at": .real(artifact.createdAt.timeIntervalSinceReferenceDate),
            "archived_at": .real(artifact.archivedAt?.timeIntervalSinceReferenceDate), "kind": .text(artifact.kind?.rawValue),
            "body_ref": .text(try record.bodyPackage.map { ArtifactBody.text(try ArtifactBody.layout(package: $0, owner: id).file) }),
            "updated_at": .real(artifact.updatedAt.timeIntervalSinceReferenceDate),
        ]
        var rows = ArtifactRows(shape: .artifact(columns: columns, hasSite: hasSite, markdown: decoded?.markdown))
        rows.linkedNotebookIDs = Array(Set(artifact.linkedNotebookIDs)).sorted()
        rows.sourceIDs = Array(Set(artifact.sourceIDs.filter { !$0.isEmpty })).sorted()
        var fields = ArtifactProjection.encodeRows(rows)
        for field in artifactFieldsNotGiven { fields.removeValue(forKey: field) }
        // A Doc whose package was not fetched and whose site folder is not on this Mac cannot be told from a
        // plain Doc by what is here: its kind is not given, so it never flips a site Doc to a Doc (F34).
        if decoded == nil, !hasSite { fields.removeValue(forKey: "kind") }
        var doc = LegacyV2Record(type: .artifact, id: id, fields: fields, giving: .owns)
        doc.wholeFields = ["linkedNotebookIDs", "sourceIDs"]
        if let revision = payload.bodyRevision { doc.hashOverrides["body"] = revision }
        mapping.records.append(doc)
    }

    /// An old draft deck's cards as draft Cards (§10, §13.6 "A draft stays a draft"), as the activation
    /// derives them (`KnowledgeStore.deriveCardDrafts`): a seeded card under `card:<deckSourceID>:<seed>`,
    /// any other under its own deck id, the first of two under one id. Each only creates its Card
    /// (`createsOnly`), so a card kept, skipped or retired since never turns back into a draft, and a card
    /// kept on the old build is told from its draft by the seed its kept Card holds (`MemoryCardTriage`).
    /// A deck in a team's zone, or whose package was not fetched (an unchanged deck's never is), gives
    /// nothing.
    static func cardDeckDrafts(_ payload: CloudKitArtifactPayload, record: LegacyRecord, context: LegacyMappingContext) throws -> [LegacyV2Record] {
        let artifact = payload.artifact
        guard record.teamID == nil, let package = record.bodyPackage,
              let source = MemoryCard.sourceID(fromDraftDeckID: artifact.id) ?? artifact.sourceIDs.first
        else { return [] }
        let markdown = try ArtifactBodyPackage.decode(package, expectedRevision: payload.bodyRevision).markdown
        let deckSource = try context.sourceWireID(source)
        var seen = Set<String>()
        var records: [LegacyV2Record] = []
        for card in FlashcardDeck.parse(markdown, fallbackTitle: "").cards {
            let id = card.seed.map { SyncIdentity.cardDraftID(deckSourceID: deckSource, seedKey: $0) } ?? card.id
            guard seen.insert(id).inserted else { continue }
            let rows = CardRows(item: nil, state: CardRows.State(
                status: "draft", deckSourceID: deckSource, origin: KnowledgeStore.wireOrigin(card.origin, seedKey: card.seed),
                seedKey: card.seed,
                draft: try KnowledgeStore.draftJSON(card, deckSourceID: deckSource, anchorSourceKey: deckSource, textHash: ""),
                kept: nil, variants: [:], alwaysAsk: false, madeBy: nil, draftedAt: card.draftedAt?.timeIntervalSinceReferenceDate,
                skippedAt: nil, retiredAt: nil, supersedes: nil, splitFrom: nil
            ))
            records.append(LegacyV2Record(type: .card, id: id, fields: CardProjection.encodeRows(rows), giving: .createsOnly))
        }
        return records
    }

    /// An old ArtifactComment: its Comment (`saveArtifactCommentRecord`).
    static func comment(_ comment: ArtifactCommentRecord, record: LegacyRecord, context: LegacyMappingContext) throws -> LegacyV2Record {
        let rows = CommentProjection.Rows(columns: [
            "artifact_id": .text(try context.wireID(.artifact, oldID: comment.artifactID, teamID: record.teamID)),
            "parent_comment_id": .text(comment.parentCommentID), "author_record_name": .text(comment.authorRecordName),
            "author_display_name": .text(comment.authorDisplayName), "body": .text(comment.body),
            "anchor_revision": .text(comment.anchorRevision), "anchor_start": .integer(Int64(comment.anchorStart)),
            "anchor_end": .integer(Int64(comment.anchorEnd)), "anchor_quote": .text(comment.anchorQuote),
            "created_at": .real(comment.createdAt.timeIntervalSinceReferenceDate), "updated_at": .real(comment.updatedAt.timeIntervalSinceReferenceDate),
            "resolved_at": .real(comment.resolvedAt?.timeIntervalSinceReferenceDate),
        ])
        return LegacyV2Record(type: .comment, id: comment.id, fields: CommentProjection.encodeRows(rows), giving: .owns)
    }
}
