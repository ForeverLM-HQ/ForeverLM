import Foundation

// MARK: - The seed's bytes (docs/cloudkit-schema-design.md §13.4 step 2 P5)

/// The body the seed sends for a Doc: this Mac's own encoding of it.
enum SeedDocBodies {
    /// The package bytes a Doc's pointer names: this Mac's own encoding when that is it; nil otherwise (the
    /// Doc was edited after the pointer was laid out, and the body publisher sends the edit).
    static func package(for pointer: FileRef, artifactID: String, store: KnowledgeStore) throws -> Data? {
        if let own = try store.loadArtifactBodyPackageForSync(artifactID), own.revision == pointer.hash { return own.data }
        return nil
    }
}
