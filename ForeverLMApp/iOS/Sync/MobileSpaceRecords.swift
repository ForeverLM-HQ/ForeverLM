import Foundation

// The Space's records under generation 2 (docs/cloudkit-schema-design.md §3.5.3, §3.5.15, §3.5.30;
// docs/docs-design.md, "The Space"): a page is an Artifact in the learner's `Library` (a team's in its
// space), its text the `body` satellite, and the learner's grouping of pages four kinds of account
// Setting the catalog leaves out (`pageSpace.`, `page.space.`, `page.pinned.`, `page.parent.`). Read
// from the replica's index with the pending patches laid over, and written as the web's generation-2
// writer writes them (`library-mutations-v2.js`: `createArtifact`, `writeArtifact`, `renameArtifact`,
// `setArtifactArchived`, `deleteArtifact`), so every client makes the same records.

// MARK: - A page's body

/// A page's body as every client stores it (§3.5.15, the Mac's `ArtifactBody`): the `ArtifactBodyPackage`
/// bytes as they are, so the satellite's FileRef `hash` is the package's revision, the one a save
/// compares; a notebook's Notes Doc alone stores gzip Markdown.
enum MobileSpaceBody {
    static let role = "body"
    static let packageMime = "application/vnd.foreverlm.article"
    static let packageFormat = "markdownPackage"
    static let notesMime = "text/markdown"
    /// Lists' preview: the Markdown on one line, at most this many characters (`NotesDoc.previewLimit`).
    static let previewLimit = 280

    /// The text a body's bytes hold, checked against the FileRef's hash.
    static func decode(_ data: Data, file: FileRef) throws -> ArtifactBodyPackage.Decoded {
        if file.mime?.lowercased() == notesMime {
            return ArtifactBodyPackage.Decoded(markdown: String(decoding: data, as: UTF8.self), attachments: [], revision: file.hash)
        }
        return try ArtifactBodyPackage.decode(data, expectedRevision: file.hash)
    }

    /// A page's new package. What the held package carries besides its Markdown goes with it: each
    /// picture the new Markdown still names, and a site's files, so a save from the phone loses nothing
    /// the Mac put in the page. A picture the Markdown names that the page does not hold is refused.
    static func encode(_ markdown: String, carrying held: ArtifactBodyPackage.Decoded?) throws -> ArtifactBodyPackage.Encoded {
        let tokens = Set(try ArtifactBodyPackage.referencedAttachmentTokens(markdown))
        let carried = (held?.attachments ?? []).filter { tokens.contains($0.token) }
        guard !carried.isEmpty else {
            return try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: nil, siteFiles: held?.siteFiles)
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("ForeverLMPageBody-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        for attachment in carried {
            try attachment.data.write(to: directory.appendingPathComponent(attachment.token, isDirectory: false))
        }
        return try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: directory, siteFiles: held?.siteFiles)
    }

    static func preview(_ markdown: String) -> SyncJSON {
        let line = markdown.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return line.isEmpty ? .null : .string(String(line.prefix(previewLimit)))
    }
}

extension MobileSatellites {
    /// Keeps bytes this phone just uploaded in the satellite cache under their FileRef, so the page it
    /// saved opens again without fetching what it already has.
    nonisolated func hold(_ data: Data, as file: FileRef) {
        let url = disk.cacheURL(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Reading the Space

extension MobileProjection {
    /// Every Setting whose key starts with one of `prefixes` (§3.5.3), by key, in `zoneKey` (the
    /// account's in `Library`). The index row of a Setting is laid over with its pending patch when the
    /// writer queues it (`MobileReplica.reindex`), so what this phone wrote and has not sent yet is read
    /// too: a space of pages made here with no page in it yet is listed. A cleared Setting is no row.
    func settings(withPrefixes prefixes: [String], zoneKey: String = libraryKey) async throws -> [String: SyncJSON] {
        try await replica.read { try Self.settings(withPrefixes: prefixes, zoneKey: zoneKey, in: $0.connection) }
    }

    static func settings(withPrefixes prefixes: [String], zoneKey: String = libraryKey, in connection: SQLiteConnection) throws -> [String: SyncJSON] {
        guard !prefixes.isEmpty else { return [:] }
        let matches = Array(repeating: "substr(key, 1, ?) = ?", count: prefixes.count).joined(separator: " OR ")
        var settings: [String: SyncJSON] = [:]
        try connection.query(
            "SELECT key, value_json FROM m_settings WHERE zone_key = ? AND (\(matches))",
            [.text(zoneKey)] + prefixes.flatMap { [SQLiteValue.integer(Int64($0.count)), .text($0)] }
        ) { row in
            guard let key = row.text(0), let text = row.text(1), let value = try? SyncJSON(parsing: Data(text.utf8)), value != .null else { return }
            settings[key] = value
        }
        return settings
    }
}

/// What the phone's Space shows under generation 2 (§3.5.15, D33): its pages from the index columns of
/// `m_artifacts`, with no payload decoded but each space's root, and the learner's grouping from the
/// four kinds of Setting. Unlike a notebook's Studio (`MobileReadModels.artifacts`), it keeps the pages
/// in Trash and every kind the Mac's Space lists (`MobileSpaceListing.isSpaceRecord`).
enum MobileSpaceReadModel {
    static let libraryKey = MobileProjection.libraryKey

    struct Snapshot: Equatable, Sendable {
        var pages: [MobileSpacePage] = []
        var organization = MobileSpaceOrganization()
        var teams: [MobileSpaceTeam] = []
    }

    static func snapshot(in replica: MobileReplica) throws -> Snapshot {
        Snapshot(pages: try pages(in: replica), organization: try organization(in: replica.connection), teams: try teams(in: replica))
    }

    /// The teams this phone holds, by name: the spaces whose root is a team's or a family's (§2.4, the Mac's
    /// `Team`), not a notebook or a page shared on its own. A team with no name yet is listed as Team.
    static func teams(in replica: MobileReplica) throws -> [MobileSpaceTeam] {
        try MobileProjection.spaces(in: replica)
            .filter { $0.kind == "team" || $0.kind == "family" }
            .map { space in
                let name = space.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return MobileSpaceTeam(id: space.spaceID, name: name.isEmpty ? "Team" : name)
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    static func organization(in connection: SQLiteConnection) throws -> MobileSpaceOrganization {
        let settings = try MobileProjection.settings(withPrefixes: MobileSpaceOrganization.preferenceKeyPrefixes, in: connection)
        return MobileSpaceOrganization(rows: settings.compactMapValues { MobileSettingValue.plist($0) })
    }

    /// The Space's pages, the newest made first: the learner's own in `Library`, then each space's (a
    /// record held in both is listed once, as theirs). With `ids`, only those. A page a member hid is
    /// kept, flagged; a mnemonic reading a notebook holds is listed there alone, unless it is in Trash
    /// (`isListedOnlyInItsNotebook`).
    static func pages(in replica: MobileReplica, ids: Set<String>? = nil) throws -> [MobileSpacePage] {
        if ids?.isEmpty == true { return [] }
        let connection = replica.connection
        let spaces = Dictionary(try MobileProjection.spaces(in: replica).map { ($0.zoneKey, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = [libraryKey] + spaces.keys.sorted()
        let marks = try MobileReadModels.Marks(in: connection)
        var notebooks = Set<String>()
        try connection.query("""
            SELECT id FROM m_notebooks
            WHERE (status IS NULL OR status NOT IN ('merged', 'moved')) AND COALESCE(merged_into, '') = '' AND COALESCE(moved_to, '') = ''
        """, []) { notebooks.insert($0.text(0) ?? "") }

        var seen = Set<String>()
        var pages: [MobileSpacePage] = []
        let wanted = ids.map { $0.sorted() }
        func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ", ") }
        try connection.query("""
            SELECT id, zone_key, kind, title, notebook_id, status, created_at, edited_at, linked_json, linked_url, body_hash, is_draft
            FROM m_artifacts WHERE zone_key IN (\(placeholders(keys.count)))\(wanted.map { " AND id IN (\(placeholders($0.count)))" } ?? "")
            ORDER BY CASE zone_key WHEN ? THEN 0 ELSE 1 END, zone_key, id
        """, keys.map { .text($0) } + (wanted ?? []).map { .text($0) } + [.text(libraryKey)]) { row in
            let id = row.text(0) ?? ""
            let zoneKey = row.text(1) ?? ""
            let kind = row.text(2) ?? "doc"
            guard MobileSpaceListing.isSpaceRecord(id: id, kind: kind), seen.insert(id).inserted else { return }
            // A Doc in the Doc space made for it (shared on its own, §9.1 `doc`, D5) is a page of this
            // library, the learner's own or one shared with them; any other space's page is its team's.
            let space = spaces[zoneKey]
            let inDocSpace = space?.isDocSpace(of: id) ?? false
            let teamID = zoneKey == libraryKey || inDocSpace ? nil : space?.spaceID
            let writable = space.map { $0.isOwned || $0.permission == "readWrite" } ?? true
            let trashed = row.text(5) == "archived"
            let home = row.text(4).flatMap { $0.isEmpty ? nil : $0 }
            let linked = MobileReadModels.members(row.text(8))
            if kind == MobileSpaceListing.readingKind, !trashed, ([home].compactMap { $0 } + linked).contains(where: notebooks.contains) { return }
            let linkedURL = row.text(9).flatMap { $0.isEmpty ? nil : $0 }
            let created = MobileReadModels.date(row.integer(6))
            let edited = MobileReadModels.date(row.integer(7))
            pages.append(MobileSpacePage(
                id: id, title: row.text(3) ?? "", kind: kind, notebookID: home, linkedNotebookIDs: linked, teamID: teamID,
                isDraft: row.integer(11) == 1, isTrashed: trashed, isHidden: marks.isHidden("art", id),
                createdAt: created ?? edited ?? .distantPast, editedAt: edited ?? created ?? .distantPast, bodyRevision: row.text(10),
                linkedURL: linkedURL, isDailyNote: teamID == nil && DailyNote.isDailyNoteID(id),
                isEditableMarkdown: teamID == nil && writable && linkedURL == nil && kind != MobileSpaceListing.readingKind
            ))
        }
        return MobileSpaceListing.sorted(pages, by: .created)
    }
}

extension MobileProjection.Space {
    /// Whether this is the Doc space made for the page `id`: a page shared on its own lives in one, with
    /// its comments, and reads as part of the library (§9.1 `doc`, D5).
    func isDocSpace(of id: String) -> Bool {
        kind == "doc" && primaryID == id
    }
}

// MARK: - Writing the Space

/// A save found the page's body moved since the editor opened it: the revision the record holds now.
struct MobileSpaceBodyMoved: Error, Equatable {
    let currentRevision: String?
}

extension MobileWrite {
    /// Where the phone holds a page: the learner's `Library` first, then a space.
    func pageZoneKey(_ id: String) throws -> String? {
        let keys = try zoneKeys(holding: .artifact, id)
        return keys.first { $0 == Self.libraryKey } ?? keys.first
    }

    /// A page as the phone holds it, its pending patch laid over, with its zone; nil when it holds none.
    func heldPage(_ id: String) throws -> (zoneKey: String, envelope: SyncEnvelope)? {
        guard let zoneKey = try pageZoneKey(id), let envelope = try held(.artifact, id, in: zoneKey) else { return nil }
        return (zoneKey, envelope)
    }

    /// Whether `zoneKey` is the Doc space made for the page `id` (§9.1 `doc`, D5).
    func isInItsDocSpace(_ id: String, zoneKey: String) throws -> Bool {
        try MobileProjection.spaces(in: replica).contains { $0.zoneKey == zoneKey && $0.isDocSpace(of: id) }
    }

    /// Trash is a status on the page and a delete takes its record: either would reach the owner of
    /// a page someone shared with this account, and everyone else it is shared with.
    private func refuseSharedWithMe(_ id: String, zoneKey: String) throws {
        guard try MobileProjection.spaces(in: replica).contains(where: {
            $0.zoneKey == zoneKey && !$0.isOwned && $0.isDocSpace(of: id)
        }) else { return }
        throw MobileSpaceError.refused("This page was shared with you, so only its owner can delete it. Remove it from your library on your Mac.")
    }

    private func requiredPage(_ id: String) throws -> (zoneKey: String, envelope: SyncEnvelope) {
        guard let page = try heldPage(id) else { throw MobileSpaceError.notFound }
        return page
    }

    /// A new page of the learner's own, a Markdown Doc in `Library` filed in no notebook, as the web's
    /// `createArtifact` makes one: its body uploaded first (`body`), then the record that names it. An
    /// empty page writes no preview, so a page the same id makes on two devices (a daily note) never
    /// clears the other's.
    mutating func createPage(_ id: String, title: String, body: FileRef, markdown: String) throws {
        var patch = RecordPatch(.artifact, id: id)
        patch.changes["kind"] = .value(.string("doc"))
        patch.changes["title"] = .value(.string(title))
        patch.changes["body"] = .value(body.value)
        patch.changes["bodyFormat"] = .value(.string(MobileSpaceBody.packageFormat))
        let preview = MobileSpaceBody.preview(markdown)
        if preview != .null { patch.changes["preview"] = .value(preview) }
        patch.changes["isDraft"] = .value(.bool(false))
        patch.changes["status"] = .value(.string("active"))
        patch.changes["madeBy"] = .value(MadeBy(route: "ios", device: deviceID, at: milliseconds).value)
        patch.changes["createdAt"] = .value(SyncJSON(milliseconds))
        try write(patch, in: Self.libraryKey)
    }

    /// A page's new body, written only while the record still holds the revision the editor opened
    /// (`expectedRevision`, nil for a page that had none), as the web's `writeArtifact` refuses a save
    /// over a body that changed meanwhile: the sync keeps the server's body on a conflict
    /// (`PrivateSyncEngine`), so a save over a moved body would lose one of the two texts unseen.
    mutating func writePageBody(_ id: String, body: FileRef, markdown: String, expectedRevision: String?) throws {
        let page = try requiredPage(id)
        guard try page.zoneKey == Self.libraryKey || isInItsDocSpace(id, zoneKey: page.zoneKey) else {
            throw MobileSpaceError.refused("A team’s page is edited on your Mac.")
        }
        let current = page.envelope.fields["body"].flatMap(FileRef.init(json:))?.hash
        guard current == expectedRevision else { throw MobileSpaceBodyMoved(currentRevision: current) }
        var patch = RecordPatch(.artifact, id: id)
        patch.changes["body"] = .value(body.value)
        patch.changes["bodyFormat"] = .value(.string(MobileSpaceBody.packageFormat))
        patch.changes["preview"] = .value(MobileSpaceBody.preview(markdown))
        try write(patch, in: page.zoneKey)
    }

    mutating func renamePage(_ id: String, to title: String) throws {
        let page = try requiredPage(id)
        var patch = RecordPatch(.artifact, id: id)
        patch.changes["title"] = .value(.string(title))
        try write(patch, in: page.zoneKey)
    }

    /// Move to Trash and Restore: the page's `status` (`ArchiveStatus`), which the Mac reads as its
    /// archive date. The record stays whole; `editedAt` moves.
    mutating func setPageTrashed(_ id: String, _ trashed: Bool) throws {
        let page = try requiredPage(id)
        if trashed { try refuseSharedWithMe(id, zoneKey: page.zoneKey) }
        var patch = RecordPatch(.artifact, id: id)
        patch.changes["status"] = .value(.string(trashed ? "archived" : "active"))
        try write(patch, in: page.zoneKey)
    }

    /// Deletes a page for good and the comments on it (same zone, §5.1), as the web's `deleteArtifact`;
    /// in a space only its owner or maker may (`SpaceWriteGuard`).
    mutating func deletePage(_ id: String) throws {
        let page = try requiredPage(id)
        try refuseSharedWithMe(id, zoneKey: page.zoneKey)
        try delete(.artifact, id, in: page.zoneKey)
        for row in try rows("""
            SELECT wire_id FROM ck_records WHERE zone_key = ? AND record_type = ?
            UNION SELECT wire_id FROM ck_patches WHERE zone_key = ? AND record_type = ?
        """, [.text(page.zoneKey), .text(SyncRecordType.comment.rawValue), .text(page.zoneKey), .text(SyncRecordType.comment.rawValue)]) {
            guard try held(.comment, row[0], in: page.zoneKey)?.fields["artifactID"]?.stringValue == id else { continue }
            try delete(.comment, row[0], in: page.zoneKey)
        }
    }

    /// The learner's grouping as the phone holds it now, its pending writes included: what each act
    /// reads again before it writes, so a row another device wrote since the last load is kept.
    func pageOrganization() throws -> MobileSpaceOrganization {
        try MobileSpaceReadModel.organization(in: connection)
    }

    /// One row of the grouping, a Setting only its own writers set (`leftOut`); nil clears it. A row
    /// already holding the value writes nothing, and clearing one the phone never held writes nothing.
    mutating func writePageRow(_ key: String, _ value: String?) throws {
        guard try stringSetting(key) != value else { return }
        try writeLeftOutSetting(key, value)
    }
}

extension MobileRecordWriter {
    /// A page's body package uploaded as its `body` satellite, acknowledged before anything points at it
    /// (§3.5.30 rule 2): in the private `Content` zone, or, for a page that lives in a space (a Doc in
    /// its Doc space), in that space's own zone, where everyone it is shared with reads it.
    func uploadPageBody(_ package: Data, pageID: String, keeping existing: FileRef?, spaceZoneKey: String? = nil) async throws -> FileRef {
        let zoneKey = spaceZoneKey ?? PrivateSyncZones.key(PrivateSyncZones.content)
        guard let blobs,
              let zone = try await replica.perform({ try BlobZone.resolve(zoneKey: zoneKey, in: $0) })
        else { throw MobileSpaceError.unavailable }
        return try await blobs.upload(package, owner: pageID, ownerType: .artifact, role: MobileSpaceBody.role, mime: MobileSpaceBody.packageMime,
                                      encoding: .identity, into: zone, keeping: existing)
    }
}
