extension StorageService {

    /// The Doc that mirrors the working notes (`WorkingNoteMirror`), made in
    /// My Library when it does not exist. Making it twice, here or on another
    /// Mac, makes one record.
    func ensureWorkingNotesDoc() async throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        if let existing = try store.loadArtifact(WorkingNoteMirror.docID) { return existing }
        do {
            return try createArtifact(
                title: WorkingNoteMirror.docTitle,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                markdown: "",
                teamID: nil,
                artifactID: WorkingNoteMirror.docID
            ).artifact
        } catch {
            if let existing = try store.loadArtifact(WorkingNoteMirror.docID) { return existing }
            throw error
        }
    }

    /// Brings the notes and their Doc into step (`WorkingNoteStore.syncWithMirror`):
    /// edits in the Doc become changes to the notes, then the notes are written
    /// back so the Doc lists them all. A newer body (the learner typing in it)
    /// is read again, three times. Failing leaves both as they were; the next
    /// sync tries again.
    func syncWorkingNotesMirror() async {
        guard WorkingNotesPreference.isEnabled else { return }
        do {
            let doc = try await ensureWorkingNotesDoc()
            let store = workingNotes()
            for attempt in 0..<3 {
                let snapshot = try artifactMarkdown(of: doc)
                let sync = await store.syncWithMirror(markdown: snapshot.markdown, revision: snapshot.revision)
                guard sync.needsWrite else { return }
                do {
                    let saved = try await writeArtifactMarkdownAndSync(
                        artifactID: doc.id,
                        markdown: sync.markdown,
                        expectedRevision: snapshot.revision,
                        versionReason: .assistantEdit
                    )
                    await store.recordMirror(revision: saved.revision)
                    return
                } catch ArtifactError.conflict where attempt < 2 {
                    continue
                }
            }
        } catch {
            // Soft: notes work without their Doc.
        }
    }
}
