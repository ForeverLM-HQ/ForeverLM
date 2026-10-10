import Foundation

/// The Source a client writes when it does not hold the record (docs/cloudkit-schema-design.md §5.4):
/// the iPhone's share sheet and captures, the web's Add sources and the hosted MCP after their first
/// complete `Catalog` pass, so a lookup that missed can never overwrite a ready source. Only create-safe
/// fields: `primaryKey` and `madeBy` (S, the first write stands), `workKeys` (set elements only add),
/// `addedAt` (N, the earliest stands), `title`, `type` and `url` under provisional stamps (millisecond 1),
/// which any real value beats, and `ingest = {ord: [0, 1], state: queued}` (X), which never lowers a
/// source that got further. A file's `pdf` FileRef rides along once its parts are acknowledged.
enum SourceSkeleton {
    /// The fields whose values only stand until a real one arrives.
    static let provisionalFields: Set<String> = ["title", "type", "url"]

    /// The skeleton's fields, as a patch onto an empty envelope.
    static func patch(
        id: String, primaryKey: String, workKeys: [String], title: String, type: String, url: String?,
        madeBy: MadeBy, addedAt: Int64, pdf: FileRef? = nil
    ) -> RecordPatch {
        var patch = RecordPatch(.source, id: id)
        patch.changes["primaryKey"] = .value(.string(primaryKey))
        patch.changes["workKeys"] = .elements(Dictionary(workKeys.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first }))
        patch.changes["title"] = .value(.string(title))
        patch.changes["type"] = .value(.string(type))
        if let url { patch.changes["url"] = .value(.string(url)) }
        patch.changes["status"] = .value(.string("active"))
        patch.changes["ingest"] = .value(.object(["ord": .array([0, 1]), "state": .string("queued")]))
        patch.changes["madeBy"] = .value(madeBy.value)
        patch.changes["addedAt"] = .value(SyncJSON(addedAt))
        if let pdf { patch.changes["files"] = .elements(["pdf": pdf.value]) }
        return patch
    }

    /// The skeleton applied to a new envelope: provisional stamps for title, type and url, and `mint` for
    /// every other path. `status` takes a provisional stamp too, since a source the client does not
    /// hold may have been archived by its owner.
    static func envelope(_ patch: RecordPatch, saltID: String, deviceID: String, mint: (StampedPath, SyncPolicy) -> SyncStamp) throws -> SyncEnvelope {
        var envelope = SyncEnvelope.new(.source, id: patch.id, saltID: saltID)
        try envelope.apply(patch) { path, policy, _ in
            if provisionalFields.contains(path.field) || path.field == "status" {
                return provisionalStamp(policy, deviceID: deviceID)
            }
            return mint(path, policy)
        }
        return envelope
    }

    static func provisionalStamp(_ policy: SyncPolicy, deviceID: String) -> SyncStamp {
        SyncStamp(policy: policy, milliseconds: Int64(SyncSchema.Limits.provisionalStampMs), counter: 0, deviceID: deviceID)
    }
}
