import Foundation

// MARK: - Which notebook a made thing belongs to (docs/notebooks-design.md, "Homing")

/// Whether something the learner made belongs to one notebook.
/// The rule is fixed by what the thing is, never by what it mentions:
///
/// - **Filed** things carry their notebooks: a Doc, a Site, an animation, a
///   course, a Goal, an Idea, a chat, a standalone picture. Each names a home
///   and links (`global_artifacts.home_notebook_id` and its notebook links,
///   `notebook_course_links` for a course's followers, an Idea's notebook
///   and Goal links, a picture's `GeneratedImageStore.Details.notebookID`). It
///   belongs to every notebook those name, and something filed under a Goal
///   belongs to the Goal's Notebook too.
/// - **Derived** things carry no notebook: a walkthrough, a spoken explainer,
///   an explainer video, a review guide, and the pictures and Memory items
///   inside them. Each rides its source and belongs to every notebook holding
///   that source. A team notebook holds the team's copy of a source, which is
///   the learner's own row seen through `LibrarySourceList.teamCopyAliases`,
///   so a walkthrough of the learner's paper belongs to the team notebook
///   holding its copy.
///
/// Citing one of a notebook's sources earns a filed thing nothing: a Doc that
/// discusses a paper is the learner's own work, filed where they filed it.
/// `ScreenRecordScope` asks these same two questions of the recording Notebook,
/// the MCP `notebook_id` filters ask them of the notebook named, and the
/// notebook's Studio outputs and the Docs tab's notebook filter ask
/// them of theirs.
///
/// Pure: built from ids the caller read, so a view, a list tool and a test
/// all get the same answer. Foundation-only and compiled into the iPhone app
/// too, whose card review scopes a notebook's cards by it
/// (`MemoryCardScope`); the half that reads the Mac's own records is
/// `NotebookMembership+Records.swift`.
struct NotebookMembership: Sendable, Equatable {
    /// The notebook: a Notebook's id.
    let notebookID: String
    /// The notebook's sources as the library lists them: its approved pool,
    /// each team copy folded into the learner's own row.
    let sourceIDs: Set<String>
    /// Each Goal's Notebook, so a thing filed under a Goal nested in the
    /// notebook is filed in the notebook.
    let goalParents: [String: String]
    /// Team copy id → the learner's own row at the same address
    /// (`LibrarySourceList.teamCopyAliases`).
    let sourceAliases: [String: String]

    init(
        notebookID: String,
        memberSourceIDs: some Sequence<String>,
        goalParents: [String: String] = [:],
        sourceAliases: [String: String] = [:]
    ) {
        self.notebookID = notebookID
        self.goalParents = goalParents
        self.sourceAliases = sourceAliases
        self.sourceIDs = Set(memberSourceIDs.map { Self.canonicalSourceID($0, aliases: sourceAliases) })
    }

    /// A filed thing: whether any of the notebooks or Goals it names is this
    /// notebook, or a Goal of it. Nil entries (no home) are skipped.
    func containsFiled(_ notebookIDs: [String?]) -> Bool {
        Self.isFiled(in: notebookID, notebookIDs: Self.filingNotebookIDs(notebookIDs, goalParents: goalParents))
    }

    /// A derived thing: whether this notebook holds the source it rides,
    /// directly or through a team copy of it.
    func containsDerived(sourceID: String) -> Bool {
        Self.isDerived(sourceID: sourceID, from: sourceIDs, aliases: sourceAliases)
    }

    /// A derived thing riding several sources (a quiz over a course's
    /// lectures): whether this notebook holds any of them.
    func containsDerived(anyOf sourceIDs: some Sequence<String>) -> Bool {
        sourceIDs.contains { containsDerived(sourceID: $0) }
    }
}

// MARK: - The two rules on their own

extension NotebookMembership {
    /// The filed rule: whether `notebookIDs` names `notebookID`. Nil on either
    /// side never matches, so a thing with no home is in no notebook and a
    /// scope with no notebook holds nothing filed.
    static func isFiled(in notebookID: String?, notebookIDs: [String?]) -> Bool {
        guard let notebookID else { return false }
        return notebookIDs.contains { $0 == notebookID }
    }

    /// The derived rule: whether `sourceID` — or the learner's own row a team
    /// copy stands for — is among `members`, which are already canonical.
    static func isDerived(sourceID: String, from members: Set<String>, aliases: [String: String] = [:]) -> Bool {
        members.contains(sourceID) || members.contains(canonicalSourceID(sourceID, aliases: aliases))
    }

    /// The notebooks a thing filed under `ids` counts as filed under: the ids
    /// themselves and each Goal's Notebook. A Goal named in an Idea's links, or
    /// the Goal a chat is filed on, files it in the Goal's Notebook as well.
    static func filingNotebookIDs(_ ids: [String?], goalParents: [String: String]) -> [String?] {
        ids + ids.map { id in id.flatMap { goalParents[$0] } }
    }

    /// The row the library lists for `sourceID`: the learner's own source
    /// when it is a team's copy of it, otherwise itself.
    static func canonicalSourceID(_ sourceID: String, aliases: [String: String]) -> String {
        aliases[sourceID] ?? sourceID
    }
}

// MARK: - Each filed kind's link set

// A Doc's, an Idea's: `NotebookMembership+Records.swift`, which reads the
// Mac's records.

extension NotebookMembership {
    /// A course: every notebook that follows it (`notebook_course_links`). A
    /// course has no home notebook; the link is the only tie.
    static func filingNotebookIDs(followedBy notebookIDs: [String]) -> [String?] {
        notebookIDs.map { Optional($0) }
    }

    func containsCourse(followedBy notebookIDs: [String]) -> Bool {
        containsFiled(Self.filingNotebookIDs(followedBy: notebookIDs))
    }
}

// MARK: - Suggesting a notebook for an unfiled thing

/// A notebook offered first for something in no notebook, by how many of its
/// sources the notebook already holds.
struct NotebookSuggestion: Sendable, Equatable {
    let notebookID: String
    let heldSourceCount: Int
}

extension NotebookMembership {
    /// One notebook a suggestion may name: its id, its pool and when it was
    /// made (the tie-break: the older notebook first).
    struct Candidate: Sendable, Equatable {
        let notebookID: String
        let sourceIDs: Set<String>
        let createdAt: Date

        init(notebookID: String, sourceIDs: some Sequence<String>, createdAt: Date) {
            self.notebookID = notebookID
            self.sourceIDs = Set(sourceIDs)
            self.createdAt = createdAt
        }
    }

    /// The notebooks holding any of `sourceIDs`, the one holding most first,
    /// then the older, then by id; a notebook holding none is not suggested.
    /// Only ever an order for the learner to choose from: nothing is filed by
    /// it (artifacts.md §3: a cancer-metabolism animation would land in a
    /// large generic notebook).
    static func suggestions(
        for sourceIDs: [String],
        among candidates: [Candidate],
        aliases: [String: String] = [:]
    ) -> [NotebookSuggestion] {
        let wanted = Set(sourceIDs.map { canonicalSourceID($0, aliases: aliases) })
        guard !wanted.isEmpty else { return [] }
        return candidates
            .compactMap { candidate -> (Candidate, Int)? in
                let held = Set(candidate.sourceIDs.map { canonicalSourceID($0, aliases: aliases) })
                let count = wanted.intersection(held).count
                return count > 0 ? (candidate, count) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
                return lhs.0.notebookID < rhs.0.notebookID
            }
            .map { NotebookSuggestion(notebookID: $0.0.notebookID, heldSourceCount: $0.1) }
    }
}
