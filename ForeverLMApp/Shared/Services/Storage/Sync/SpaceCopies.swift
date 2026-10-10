import Foundation

// MARK: - Copies into a space (docs/cloudkit-schema-design.md §4.3, §5.3 "copy", §9.3, §9.4), generation 2

extension KnowledgeStore {
    /// The space's copy of a source (§9.4): the space's own row of it when it holds one under the
    /// source's wire id, else a new row under `SpaceLocalID`'s local id with the space's team id and
    /// the source's wire id, made as a team copy is (`teamCopy`): active, filed under nothing, with no
    /// member-local value (§9.3: who found it and how stays in the learner's own Marks). Its FileRefs
    /// travel verbatim (D41), so the copy names the satellites the personal source names; BlobStore
    /// puts them into the space's zone when the copy is sent. `fileCopy` keeps a copy of a local file
    /// for the space, as a team copy keeps one.
    @discardableResult
    func copySourceIntoSpace(_ sourceID: String, spaceID: String, fileCopy: (String) throws -> String? = { _ in nil }) throws -> String {
        let teamID = try SpaceRows.localTeamID(spaceID: spaceID, connection: self)
        guard let original = try loadSourceForSync(sourceID) else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) does not exist.")
        }
        if original.teamID == teamID { return original.id }
        let wireID = try scalarText("SELECT wire_key FROM sources WHERE id = ?", [.text(sourceID)]) ?? sourceID
        if let held = try scalarText("SELECT id FROM sources WHERE team_id = ? AND wire_key = ? ORDER BY id LIMIT 1", [.text(teamID), .text(wireID)]) {
            return held
        }
        let copyID = SpaceLocalID.localID(spaceID: spaceID, type: .source, wireID: wireID)
        var copy = try teamCopy(of: original, id: copyID, teamID: teamID, membership: nil, fileCopy: fileCopy)
        copy.discoveryOrigin = nil
        try saveSource(copy)
        try execute("UPDATE sources SET wire_id = ? WHERE id = ?", [.text(wireID), .text(copyID)])
        for (table, element) in [("source_files", "role"), ("source_derived", "kind")] {
            try execute("""
                INSERT INTO \(table) (source_id, \(element), file_ref, local_path)
                SELECT ?, \(element), file_ref, local_path FROM \(table) WHERE source_id = ?
                ON CONFLICT(source_id, \(element)) DO NOTHING
            """, [.text(copyID), .text(sourceID)])
        }
        try execute("""
            INSERT INTO source_work_keys (source_id, work_key) SELECT ?, work_key FROM source_work_keys WHERE source_id = ?
            ON CONFLICT(source_id, work_key) DO NOTHING
        """, [.text(copyID), .text(sourceID)])
        if let zoneKey = try ReplicaPlacement(connection: self).zoneKey(of: .space(spaceID)) {
            try recordIdentity(zoneKey: zoneKey, recordType: SyncRecordType.source.rawValue, wireID: wireID, localID: copyID)
        }
        return copyID
    }

    /// Files a source into a space notebook (§9.4, §5.4): the space's copy of it first, then the
    /// notebook's Entry through the app's own membership write, as `fileJobSource` files into a
    /// personal notebook (an approved source arrives ticked, a pending one is a suggestion). The Entry
    /// is named by wire ids (`keepNotebookRowsForGeneration2`). Returns the copy's local id.
    @discardableResult
    func fileIntoSpaceNotebook(_ sourceID: String, notebookID: String, spaceID: String, approval: String,
                               fileCopy: (String) throws -> String? = { _ in nil }) throws -> String {
        let copyID = try copySourceIntoSpace(sourceID, spaceID: spaceID, fileCopy: fileCopy)
        try fileJobSource(copyID, into: notebookID, approval: approval)
        try SpaceRows.recordEntryIdentities(notebookIDs: [notebookID], teamZones: try teamZoneKeys(), connection: self)
        return copyID
    }
}

extension KnowledgeStore {
    /// A course shared into a team's space (§5.5, revision 9): a copy, never a move. Generation 1's
    /// team copy writes the Course, its Lessons, Quizzes and lesson items under new ids
    /// (`TeamContentIdentity.courseID`) with every source its lessons name and their files; then every
    /// row of the space takes its wire id and identity, so the copy is sent into the space. The
    /// original stays as it was.
    func copyCourseIntoSpace(_ courseID: String, spaceID: String, fileCopy: (String) throws -> String?) throws -> CourseTeamCopy {
        let teamID = try SpaceRows.localTeamID(spaceID: spaceID, connection: self)
        let copy = try copyCourseIntoTeam(courseID: courseID, teamID: teamID, fileCopy: fileCopy)
        guard let zoneKey = try ReplicaPlacement(connection: self).zoneKey(of: .space(spaceID)) else { return copy }
        try inDerivationTransaction { try SpaceRows.adopt(teamID: teamID, zoneKey: zoneKey, connection: $0) }
        return copy
    }
}

/// Files the space copies keep (§9.4): beside generation 1's team copies, under the content root's
/// `Teams/<team id>/`, so deleting the original never takes the space's copy with it.
enum SpaceCopyFiles {
    static func copy(relativePath: String, teamID: String) throws -> String? {
        let source = URL(fileURLWithPath: StorageService.absoluteSourcePath(relativePath))
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let directory = URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true)
            .appendingPathComponent("Teams", isDirectory: true).appendingPathComponent(teamID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        return StorageService.relativeSourcePath(destination.path)
    }
}
