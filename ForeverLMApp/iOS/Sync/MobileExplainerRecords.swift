import Foundation

// An explainer written on the phone under generation 2 (docs/cloudkit-schema-design.md §3.5.4, §3.5.30,
// §5.4; explainer-design.md; §14.2 WP20c). It stays what every client makes of it: an article-typed Source
// in the learner's `Catalog` whose url is `foreverlm://explainer/<sourceID>`, under the id the Mac derives
// from that url (`GeneratedExplainer.sourceID(explaining:)`), with the script as its `files.text`
// satellite. So the Mac's Explain button, the phone's reader and Listen find it as they find any source,
// and a rewrite from any device replaces the one record.

/// What the phone writes about the source an explainer explains.
struct MobileExplainerOrigin: Equatable, Sendable {
    let sourceID: String
    let title: String
    let author: String?

    init(sourceID: String, title: String, author: String? = nil) {
        self.sourceID = sourceID
        self.title = title
        self.author = author
    }

    init(_ source: MobileCloudSource) {
        self.init(sourceID: source.id, title: source.title, author: source.author)
    }
}

extension MobileWrite {
    /// The explainer's Source, pointed at a script whose `text` satellite is already uploaded and
    /// acknowledged. Made once with its create-time fields (the key its id was minted from, its route, when
    /// it was added, `ingest` ready, the member's provenance Mark); every save writes its title, its
    /// author, the script's hash and length, and the pointer, and makes it active again. `addedAt` is the
    /// earliest (N), so a rewrite keeps the row's place in the library.
    mutating func saveExplainer(_ origin: MobileExplainerOrigin, script: String, text file: FileRef) throws -> String {
        let url = ExplainerScript.url(explaining: origin.sourceID)
        guard let key = WorkKey.normalizeRemote("url:\(url)") else { throw MobileRecordWriterError.sourceGone }
        let id = SyncIdentity.sourceID(normalizedURL: String(key.dropFirst(4)))
        let held = try held(.source, id, in: Self.catalogKey)
        var patch = RecordPatch(.source, id: id)
        if held == nil {
            patch.changes["primaryKey"] = .value(.string(key))
            patch.changes["workKeys"] = .elements([key: .bool(true)])
            patch.changes["url"] = .value(.string(url))
            patch.changes["type"] = .value(.string("article"))
            patch.changes["madeBy"] = .value(MadeBy(route: "ios", device: deviceID, at: milliseconds).value)
            patch.changes["addedAt"] = .value(SyncJSON(milliseconds))
        }
        if held?.fields["ingest"]?["state"]?.stringValue != "ready" {
            patch.changes["ingest"] = .value(.object([
                "ord": .array([0, 4]), "state": .string("ready"), "at": SyncJSON(milliseconds), "device": .string(deviceID),
            ]))
        }
        patch.changes["title"] = .value(.string(ExplainerScript.title(for: origin.title)))
        patch.changes["status"] = .value(.string("active"))
        if let author = origin.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            patch.changes["authors"] = .value(.array([.string(author)]))
        }
        patch.changes["meta"] = .elements(["siteName": .string(ExplainerScript.domain)])
        patch.changes["contentHash"] = .value(.string(file.hash))
        patch.changes["metrics"] = .value(.object([
            "wordCount": SyncJSON(Int64(ExplainerScript.wordCount(of: script))), "textChars": SyncJSON(Int64(script.count)),
        ]))
        patch.changes["files"] = .elements(["text": file.value])
        try write(patch, in: Self.catalogKey)
        if held == nil {
            try writeMark("provenance", target: "src:\(id)", on: true, value: .object(["origin": .string("manual"), "at": SyncJSON(milliseconds)]))
        }
        return id
    }

    /// The `text` satellite an explainer's Source points at now, when the phone holds one.
    func explainerText(_ id: String) throws -> FileRef? {
        try held(.source, id, in: Self.catalogKey)?.fields["files"]?["text"].flatMap(FileRef.init(json:))
    }
}

extension MobileRecordWriter {
    /// Saves an explainer: its script uploaded as the `text` satellite (gzip) in the private `Content` zone
    /// and acknowledged first, then the Source pointing at it (§3.5.30 rule 2). The same script saved again
    /// keeps the satellite it has. Returns the explainer's id.
    func saveExplainer(_ origin: MobileExplainerOrigin, script: String) async throws -> String {
        let clean = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MobileCloudMutationError.emptyExplainerScript }
        let id = MobileCloudMutationService.explainerSourceID(explaining: origin.sourceID)
        guard let blobs,
              let zone = try await replica.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { throw MobileRecordWriterError.zoneNotHeld }
        let existing = try await read { try $0.explainerText(id) }
        let file = try await blobs.upload(Data(clean.utf8), owner: id, ownerType: .source, role: "text", mime: "text/plain", encoding: .gzip,
                                          into: zone, keeping: existing)
        return try await transaction { try $0.saveExplainer(origin, script: clean, text: file) }
    }
}
