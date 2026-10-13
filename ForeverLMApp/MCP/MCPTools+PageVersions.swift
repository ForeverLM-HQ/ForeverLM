import Foundation

// MARK: - A page's version history over MCP
//
// `list_doc_versions` and `restore_doc_version`: the page menu's Version
// History… (docs/docs-design.md, "Version history"). A version is a body this
// Mac kept just before something replaced it (`PageVersionHistory`, in
// `.appdata/PageHistory` beside knowledge.db), so both tools are this Mac's
// and the hosted gateway lists them as desktop-only. A restore goes through
// `StorageService.restorePageVersion`, the ordinary save the sheet's Restore
// This Version uses, which keeps the body it replaces as a version first.

extension MCPDataStore {

    /// The page's versions on this Mac, newest first, with each one's size;
    /// with `versionID`, that version's Markdown too, whole or by character
    /// range as `read_doc` reads a body.
    func listDocVersions(
        artifactID rawArtifactID: String,
        versionID rawVersionID: String? = nil,
        start: Int? = nil,
        length: Int? = nil
    ) async throws -> String {
        let artifactID = rawArtifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty else { throw MCPError.invalidInput("doc_id is required. Use list_docs to find it.") }
        let current = try await notebookFileStorage.artifactMarkdown(artifactID)
        let versions = try await notebookFileStorage.pageVersions(artifactID: artifactID)
        let byteCounts = try await notebookFileStorage.pageVersionByteCounts(artifactID: artifactID, versions: versions)
        var payload: [String: Any] = [
            "doc": artifactPayload(current.artifact),
            "current": [
                "revision": current.revision,
                "characters": current.markdown.count,
                "bytes": current.markdown.utf8.count,
                "updated_at": ISO8601DateFormatter().string(from: current.artifact.updatedAt),
            ] as [String: Any],
            "version_count": versions.count,
            "versions": versions.map { version in
                Self.docVersionRow(version, bytes: byteCounts[version.id])
            },
            "can_restore": Self.docVersionRestoreRefusal(current) == nil,
            "guidance": versions.isEmpty
                ? "This Mac keeps no earlier version of this page yet. A version is kept when an assistant or a restore replaces the body, when the learner's typing has run ten minutes past the newest version, or when the page loses more than half its text at once; another Mac keeps its own."
                : "Each version is the page's body as it stood just before something replaced it, kept on this Mac only (another Mac, the iPhone and the web keep none of these). reason says what replaced it: learner_edit the learner's typing, assistant_edit an assistant's write, another_device a body from another device, restore a restore. Pass version_id to read one; restore_doc_version makes one the page again and keeps the current body as a version first, so a restore is undone the same way.",
        ]
        if let refusal = Self.docVersionRestoreRefusal(current) {
            payload["restore_refused_because"] = refusal
        }
        let versionID = rawVersionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !versionID.isEmpty {
            let version = try Self.docVersion(versionID, in: versions, title: current.artifact.title)
            let body = try await notebookFileStorage.pageVersionMarkdown(artifactID: artifactID, version: version)
            let total = body.count
            let offset = start ?? 0
            guard offset >= 0, offset <= total else {
                throw MCPError.invalidInput("start must be between 0 and \(total).")
            }
            let requestedLength = length ?? (total - offset)
            guard length == nil || (1...50_000).contains(requestedLength) else {
                throw MCPError.invalidInput("length must be between 1 and 50000.")
            }
            let endOffset = min(total, offset + requestedLength)
            let lower = body.index(body.startIndex, offsetBy: offset)
            let upper = body.index(body.startIndex, offsetBy: endOffset)
            var row = Self.docVersionRow(version, bytes: byteCounts[version.id])
            row["markdown"] = String(body[lower..<upper])
            row["range_start"] = offset
            row["range_end"] = endOffset
            row["total_characters"] = total
            row["is_complete"] = offset == 0 && endOffset == total
            payload["version"] = row
        }
        return try jsonString(payload)
    }

    /// **Restore This Version**: the version becomes the page's body through
    /// the ordinary save, with the page's current revision, and the body it
    /// replaces is kept as a `restore` version, whose id the answer names so
    /// the restore can be undone. Refused where the app's sheet offers no
    /// Restore: a team's page, and a linked page, whose body is not
    /// ForeverLM's; and for the records write_doc refuses.
    func restoreDocVersion(
        artifactID rawArtifactID: String,
        versionID rawVersionID: String,
        expectedRevision rawExpectedRevision: String? = nil,
        publish: Bool = false
    ) async throws -> String {
        let artifactID = rawArtifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty else { throw MCPError.invalidInput("doc_id is required. Use list_docs to find it.") }
        let versionID = rawVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !versionID.isEmpty else {
            throw MCPError.invalidInput("version_id is required. Use list_doc_versions to find it.")
        }
        let current = try await notebookFileStorage.artifactMarkdown(artifactID)
        // The records write_doc refuses say why in its words first.
        try Self.refuseAudioOverviewChange(current, doing: "restore_doc_version")
        try Self.refuseMnemonicReadingChange(current, doing: "restore_doc_version")
        if let refusal = Self.docVersionRestoreRefusal(current) {
            throw MCPError.invalidInput("Nothing was restored. \(refusal)")
        }
        let before = try await notebookFileStorage.pageVersions(artifactID: artifactID)
        let version = try Self.docVersion(versionID, in: before, title: current.artifact.title)
        let expectedRevision = rawExpectedRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedRevision.isEmpty, current.revision.caseInsensitiveCompare(expectedRevision) != .orderedSame {
            throw MCPError.invalidInput(
                "Nothing was restored. ‘\(current.artifact.title)’ changed after you read it — the learner may be editing it right now. Call list_doc_versions or read_doc again and restore from the revision it returns, or leave expected_revision out to restore over whatever the page holds now (it is kept as a version first)."
            )
        }
        let restored = try await notebookFileStorage.restorePageVersion(
            artifactID: artifactID,
            version: version,
            expectedRevision: current.revision
        )
        // The body the restore replaced, kept as a version of its own.
        let known = Set(before.map(\.id))
        let kept = try await notebookFileStorage.pageVersions(artifactID: artifactID)
            .first { $0.reason == .restore && !known.contains($0.id) }
        var payload: [String: Any] = [
            "doc": artifactPayload(restored.artifact),
            "revision": restored.revision,
            "restored_version": Self.docVersionRow(version, bytes: nil),
            "replaced_body_version_id": kept.map { $0.id as Any } ?? NSNull(),
            "message": kept == nil
                ? "Restored ‘\(restored.artifact.title)’ to the version from \(ISO8601DateFormatter().string(from: version.savedAt)). The page already held that text, so no new version was kept."
                : "Restored ‘\(restored.artifact.title)’ to the version from \(ISO8601DateFormatter().string(from: version.savedAt)). The body it replaced is kept as replaced_body_version_id; restore_doc_version with that id undoes this.",
        ]
        await finishPublishedPage(&payload, snapshot: restored, republish: publish)
        return try jsonString(payload)
    }

    /// Why the page's versions are read but never restored here, as the
    /// app's Page activity offers no Restore, or write_doc writes no body;
    /// nil when they can be.
    private static func docVersionRestoreRefusal(_ snapshot: ArtifactMarkdownSnapshot) -> String? {
        if AudioOverviewScript.isOverview(snapshot.artifact, markdown: snapshot.markdown) {
            return "‘\(snapshot.artifact.title)’ is a Notebook's audio overview, whose Markdown is only the recipe it was made from."
        }
        if snapshot.artifact.isMnemonicReading(markdown: snapshot.markdown) {
            return "‘\(snapshot.artifact.title)’ is a mnemonic reading, whose Markdown is its questions."
        }
        if snapshot.artifact.isLinked {
            let label = snapshot.artifact.linkedKind?.label ?? "linked page"
            let owner = snapshot.artifact.linkedKind?.productName ?? "the product that owns it"
            return "‘\(snapshot.artifact.title)’ is a \(label): its text here is a read-only copy of the page at \(snapshot.artifact.linkedURL ?? ""), and an earlier version of it is restored in \(owner)."
        }
        if snapshot.artifact.teamID != nil {
            return "‘\(snapshot.artifact.title)’ is a team's page: as in ForeverLM's Page activity, its versions on this Mac are read and copied, never restored over the team's copy."
        }
        return nil
    }

    private static func docVersion(_ versionID: String, in versions: [PageVersion], title: String) throws -> PageVersion {
        guard let version = versions.first(where: { $0.id == versionID }) else {
            throw MCPError.notFound(
                "Version not found: \(versionID). Use list_doc_versions to see the versions of ‘\(title)’ this Mac keeps."
            )
        }
        return version
    }

    private static func docVersionRow(_ version: PageVersion, bytes: Int?) -> [String: Any] {
        var row: [String: Any] = [
            "version_id": version.id,
            "saved_at": ISO8601DateFormatter().string(from: version.savedAt),
            "reason": docVersionReasonName(version.reason),
            // What the app's list says beside the time.
            "summary": version.reason.summary,
        ]
        if let bytes { row["bytes"] = bytes }
        return row
    }

    private static func docVersionReasonName(_ reason: PageVersionReason) -> String {
        switch reason {
        case .learnerEdit: return "learner_edit"
        case .assistantEdit: return "assistant_edit"
        case .anotherDevice: return "another_device"
        case .restore: return "restore"
        }
    }
}
