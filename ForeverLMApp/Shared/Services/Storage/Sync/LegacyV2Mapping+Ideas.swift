import Foundation

// MARK: - Ideas (docs/cloudkit-schema-design.md §10, the `Idea` row)

extension LegacyV2Mapping {
    /// An old Idea: its Idea record of kind `idea`, links included, encoded by `IdeaProjection` from the
    /// rows the old payload gives (`saveIdeaRecord` writes the same ones), with what the replica already
    /// holds, as the projection reads it. The links are given whole: a link the old record no longer lists
    /// leaves the record. `kind` and `madeBy` are first-writer defaults the old payload never carried, so
    /// only a creation takes them.
    static func idea(_ payload: CloudKitIdeaPayload, context: LegacyMappingContext) throws -> LegacyV2Record {
        let idea = payload.idea
        let rows = IdeaRows(
            id: idea.id, title: IdeaRecord.normalizedTitle(idea.title), notes: idea.notes, status: idea.status.rawValue,
            createdAt: idea.createdAt.timeIntervalSinceReferenceDate, updatedAt: idea.updatedAt.timeIntervalSinceReferenceDate,
            links: KnowledgeStore.dedupedIdeaLinks(idea.links).map {
                IdeaRows.Link(kind: $0.kind.rawValue, targetID: $0.targetID, addedAt: $0.addedAt.timeIntervalSinceReferenceDate)
            },
            held: try context.heldIdeaFields(idea.id)
        )
        var record = LegacyV2Record(type: .idea, id: idea.id, fields: IdeaProjection.encodeRows(rows), giving: .owns)
        record.wholeFields = ["links"]
        record.createOnlyFields = ["kind", "madeBy"]
        return record
    }
}
