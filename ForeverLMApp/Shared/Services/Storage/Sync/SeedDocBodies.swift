import Foundation
import OSLog

// MARK: - The seed's bytes (docs/cloudkit-schema-design.md §13.4 step 2 P4b and P5, §3.5.30 rule 2's exception)

/// Chooses each Doc's body before the seed sends its record (R7-2, R8-m6): the Mac's own encoding when that
/// reproduces the old record's `bodyRevision`, else the old package the catch-up's walk staged when it
/// decodes to this Mac's body (the same Markdown, attachments and site files: only another client's encoder
/// differs), else the Mac's own encoding, which is what an edit the old world never received (an undrained
/// one, one the catch-up kept, or its clean merge) leaves. The pointer a Doc's record carries (`body_ref`)
/// is laid out from the chosen package, so its FileRef's `hash` is the base's exactly when this Mac holds the
/// old-world body, and a later old-world edit counts as both worlds changing the body only when the Mac
/// holds an edit of its own (§13.6).
enum SeedDocBodies {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverSeed")

    /// The staged old packages of one Doc, by `OldContainerStagedPackages`' file naming.
    static func stagedPackages(artifactID: String, store: KnowledgeStore) -> [Data] {
        let prefix = SyncIdentity.sha256Hex(Data(artifactID.utf8)).prefix(24) + "."
        let folder = OldContainerStagedPackages.folder(store)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
    }

    /// Re-points each Doc whose old package decodes to this Mac's body at that package. Runs under the apply
    /// guard (it is a derived pointer, not an edit), before P1 sends the Doc's record. Returns how many
    /// pointers moved.
    @discardableResult
    static func choose(in store: KnowledgeStore) throws -> Int {
        var docs: [(id: String, owner: String, kind: String?)] = []
        try store.query("SELECT id, wire_key, kind FROM global_artifacts WHERE team_id IS NULL AND body_ref IS NOT NULL ORDER BY id", []) { row in
            if let id = row.text(0) { docs.append((id, row.text(1) ?? id, row.text(2))) }
        }
        var moves: [(id: String, ref: String)] = []
        for doc in docs where !ArtifactBody.isCardDeck(id: doc.id, kind: doc.kind) {
            let staged = stagedPackages(artifactID: doc.id, store: store)
            guard !staged.isEmpty, let own = try store.loadArtifactBodyPackageForSync(doc.id),
                  let mine = try? ArtifactBodyPackage.decode(own.data) else { continue }
            for package in staged where SyncIdentity.sha256Hex(package) != own.revision {
                guard let theirs = try? ArtifactBodyPackage.decode(package),
                      theirs.markdown == mine.markdown, theirs.attachments == mine.attachments, theirs.siteFiles == mine.siteFiles
                else { continue }
                moves.append((doc.id, ArtifactBody.text(try ArtifactBody.layout(package: package, owner: doc.owner).file)))
                break
            }
        }
        guard !moves.isEmpty else { return 0 }
        try store.replica.apply { _ in
            for move in moves {
                try store.execute("UPDATE global_artifacts SET body_ref = ? WHERE id = ?", [.text(move.ref), .text(move.id)])
            }
        }
        logger.notice("\(moves.count) Docs are seeded from the package the old world holds")
        return moves.count
    }

    /// The package bytes a Doc's pointer names: the staged old package whose hash it is, else this Mac's own
    /// encoding when that is it; nil when neither (the Doc was edited after the pointer was laid out, and
    /// the body publisher sends the edit).
    static func package(for pointer: FileRef, artifactID: String, store: KnowledgeStore) throws -> Data? {
        if let staged = stagedPackages(artifactID: artifactID, store: store).first(where: { SyncIdentity.sha256Hex($0) == pointer.hash }) {
            return staged
        }
        if let own = try store.loadArtifactBodyPackageForSync(artifactID), own.revision == pointer.hash { return own.data }
        return nil
    }
}
