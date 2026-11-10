import Foundation

// MARK: - Schema 159: what the Artifact and Comment records need (§12.7)

extension KnowledgeStore {
    /// The tables schema 159 adds (docs/cloudkit-schema-design.md §12.7), created empty: DDL only, like
    /// every step from 154 on, beside `global_artifacts.body_ref`. Generation 1 never reads or writes
    /// them; the generation-2 activation and the body publisher fill them.
    static let artifactSyncTables: [ReplicaSchemaTable] = [
        // The satellites an Artifact names besides a Doc's body (§3.5.15): one row per element of its
        // `files` map, and for a Notes Doc, which has no `global_artifacts` row, its body pointer under
        // the key `#body`. The FileRef as JSON, and where this Mac holds the bytes, relative to the
        // store's folder, when they are staged. No foreign key: a Notes Doc's id names a notebook.
        ReplicaSchemaTable("artifact_files", [
            ("artifact_id", "TEXT NOT NULL"),
            ("file_key", "TEXT NOT NULL"),
            ("file_ref", "TEXT NOT NULL"),
            ("local_path", "TEXT"),
        ], constraints: ["PRIMARY KEY (artifact_id, file_key)"]),
        // The time this Mac's seed or reconcile had a body's upload acknowledged (`sent_at`, WP16),
        // keyed by wire id. `base_hash` and `base_text` are no longer written.
        ReplicaSchemaTable("ck_body_sends", [
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("field", "TEXT NOT NULL"),
            ("base_hash", "TEXT"),
            ("base_text", "TEXT"),
            ("sent_at", "REAL"),
        ], constraints: ["PRIMARY KEY (record_type, wire_id, field)"]),
    ]

    /// Creates schema 159's tables where missing: empty, DDL only.
    func createArtifactSyncTables() throws {
        for table in Self.artifactSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}

// MARK: - The activation's derivation for Artifacts (§13.3 step 3c)

extension KnowledgeStore {
    /// WP11's derivation: every Doc's body pointer and every notebook's Notes Doc pointer, laid out from
    /// the bodies this Mac holds as the publisher lays them out, without uploading them (the cutover
    /// seed sends pointers and then bytes, §3.5.30 rule 2's exception). A Doc's FileRef hashes its
    /// `ArtifactBodyPackage` bytes, so it carries the `bodyRevision` generation 1 gives the same package
    /// (§13.6). The sent body is kept for the seed's acknowledgement to make it the base. Idempotent and
    /// bounded by the library's Docs and notebooks; drafts decks are left out (retired, §10).
    static let artifactActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "artifactBodyRefs") { store in try store.deriveArtifactBodyRefs() },
    ]

    func deriveArtifactBodyRefs() throws {
        var docs: [(id: String, owner: String, kind: String?)] = []
        try query("SELECT id, wire_key, kind FROM global_artifacts WHERE team_id IS NULL ORDER BY id", []) { row in
            if let id = row.text(0) { docs.append((id, row.text(1) ?? id, row.text(2))) }
        }
        var laid: [(id: String, ref: String?)] = []
        for doc in docs where !ArtifactBody.isCardDeck(id: doc.id, kind: doc.kind) {
            guard let markdown = try loadArtifactMarkdownForSync(doc.id), let package = try loadArtifactBodyPackageForSync(doc.id) else {
                laid.append((doc.id, nil))
                continue
            }
            let file = try ArtifactBody.layout(package: package.data, owner: doc.owner).file
            try saveArtifactSidecar(markdown, artifactID: doc.id, name: Self.sentBodyName(hash: file.hash))
            laid.append((doc.id, ArtifactBody.text(file)))
        }
        var notes: [(artifactID: String, text: String)] = []
        try query("SELECT id, notes FROM learning_goals WHERE entity_kind = ? AND team_id IS NULL ORDER BY id", [.text(LearningGoalEntityKind.notebook)]) { row in
            guard let id = row.text(0) else { return }
            notes.append((NotesDoc.id(notebookID: id), NotesDoc.text(row.text(1))))
        }
        var notesLaid: [(artifactID: String, ref: String?, staged: String?)] = []
        for note in notes {
            guard !note.text.isEmpty else {
                notesLaid.append((note.artifactID, nil, nil))
                continue
            }
            guard let notebookID = NotesDoc.notebookID(of: note.artifactID),
                  let body = try NotesDoc.body(notebookID: notebookID, notes: note.text) else { continue }
            notesLaid.append((note.artifactID, ArtifactBody.text(body.file), try stageNotesBody(note.text, owner: note.artifactID, hash: body.file.hash)))
        }
        try inDerivationTransaction { store in
            for doc in laid {
                try store.execute("UPDATE global_artifacts SET body_ref = ? WHERE id = ?", [.text(doc.ref), .text(doc.id)])
            }
            for note in notesLaid {
                guard let ref = note.ref else {
                    try store.execute("DELETE FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(note.artifactID), .text(ArtifactBody.notesKey)])
                    continue
                }
                try store.execute("""
                    INSERT INTO artifact_files (artifact_id, file_key, file_ref, local_path) VALUES (?, ?, ?, ?)
                    ON CONFLICT(artifact_id, file_key) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
                """, [.text(note.artifactID), .text(ArtifactBody.notesKey), .text(ref), .text(note.staged)])
            }
        }
    }
}
