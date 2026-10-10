import Foundation

// MARK: - The Mac's filed records

/// `NotebookMembership` over the Mac's own records: a Doc's, Site's,
/// animation's or audio overview's home and links, and an Idea's Notebook and
/// Goal links. Kept apart from the rule itself (`NotebookMembership.swift`),
/// which is Foundation-only and compiled into the iPhone app too, where these
/// record types do not exist.
extension NotebookMembership {
    /// A Doc, Site, animation or audio overview: its home and its links, each
    /// notebook once. A record may link its own home as well, and a list of
    /// its notebooks named that one twice (the Space's Notebook column read
    /// "Mitochondria, Mitochondria" on 2026-10-06).
    static func filingNotebookIDs(of artifact: ArtifactRecord) -> [String?] {
        var named = Set<String>()
        return ([artifact.homeNotebookID] + artifact.linkedNotebookIDs.map { Optional($0) }).filter { id in
            id.map { named.insert($0).inserted } ?? true
        }
    }

    /// An Idea: the Notebooks and Goals it links.
    static func filingNotebookIDs(of idea: IdeaRecord) -> [String?] {
        idea.links
            .filter { $0.kind == .notebook || $0.kind == .goal }
            .map { Optional($0.targetID) }
    }

    func contains(_ artifact: ArtifactRecord) -> Bool {
        containsFiled(Self.filingNotebookIDs(of: artifact))
    }

    func contains(_ idea: IdeaRecord) -> Bool {
        containsFiled(Self.filingNotebookIDs(of: idea))
    }
}
