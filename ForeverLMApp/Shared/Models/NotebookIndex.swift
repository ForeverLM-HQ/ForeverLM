import Foundation

// MARK: - Homing on screen (shell stage 4; docs/notebooks-design.md, "Homing")
//
// The pure half of what the home's Docs tab and the made things' menus show
// about notebooks: which notebooks an entry lives in, the index's notebook
// filter with "Not in a notebook", and the order Add to Notebook ▸ offers
// them in. Built from ids the caller read, so a view and a test get the same
// answer; nothing here writes.

/// Where one made thing lives, by what it is
/// (`NotebookMembership`): a **filed** thing names its notebooks — a Doc's,
/// Site's or animation's home and links, an
/// Idea's links, a Goal's Notebook, a standalone picture's notebook — and a
/// **derived** thing rides sources: a walkthrough, an explainer video.
struct NotebookIndexFiling: Equatable, Sendable {
    /// The notebooks (and Goals) a filed thing names; nil entries are none.
    var filedNotebookIDs: [String?] = []
    /// The sources a derived thing rides.
    var derivedSourceIDs: [String] = []

    static func filed(_ notebookIDs: [String?]) -> NotebookIndexFiling {
        NotebookIndexFiling(filedNotebookIDs: notebookIDs)
    }

    static func derived(fromSources sourceIDs: [String]) -> NotebookIndexFiling {
        NotebookIndexFiling(derivedSourceIDs: sourceIDs)
    }

    /// The notebooks of the open library this entry lives in: those its
    /// filing names (a Goal counting as its Notebook), and those holding a
    /// source it rides. `notebookIDs` is the open library's notebooks, so a
    /// home naming a notebook the library no longer holds counts as none;
    /// `members` is each notebook's sources as the library lists them.
    func notebooks(
        among notebookIDs: Set<String>,
        members: [String: Set<String>],
        goalParents: [String: String] = [:]
    ) -> Set<String> {
        var held = Set(
            NotebookMembership.filingNotebookIDs(filedNotebookIDs, goalParents: goalParents)
                .compactMap { $0 }
                .filter(notebookIDs.contains)
        )
        if !derivedSourceIDs.isEmpty {
            for notebookID in notebookIDs where !held.contains(notebookID) {
                let pool = members[notebookID] ?? []
                if derivedSourceIDs.contains(where: { NotebookMembership.isDerived(sourceID: $0, from: pool) }) {
                    held.insert(notebookID)
                }
            }
        }
        return held
    }
}

/// The Docs tab's notebook filter: every notebook's work, one
/// notebook's, or what lives in none (artifacts.md §4).
enum ArtifactsNotebookFilter: Hashable, Sendable {
    case all
    case notInNotebook
    case notebook(String)

    /// Whether an entry living in `notebooks` passes.
    func admits(livingIn notebooks: Set<String>) -> Bool {
        switch self {
        case .all: return true
        case .notInNotebook: return notebooks.isEmpty
        case .notebook(let id): return notebooks.contains(id)
        }
    }

    /// The filter as it applies now: a notebook gone from the open library
    /// since it was chosen (deleted, archived, another library's) is every
    /// notebook again, as the team filter does for a team left.
    func effective(notebookIDs: Set<String>) -> ArtifactsNotebookFilter {
        if case .notebook(let id) = self, !notebookIDs.contains(id) { return .all }
        return self
    }
}

/// The notebooks an Add to Notebook ▸ menu lists, in order: the suggested
/// ones first (`NotebookMembership.suggestions`, those holding most of the
/// thing's sources), then the rest by title. A notebook the thing already
/// lives in is not offered: its Remove from Notebook is.
enum NotebookMenuChoices {
    struct Choice: Equatable, Sendable, Identifiable {
        let notebookID: String
        let title: String
        let isSuggested: Bool

        var id: String { notebookID }
    }

    static func ordered(
        notebooks: [(id: String, title: String)],
        suggestions: [NotebookSuggestion],
        excluding livesIn: Set<String> = []
    ) -> [Choice] {
        let titles = Dictionary(notebooks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var seen = livesIn
        var choices: [Choice] = []
        for suggestion in suggestions {
            guard let title = titles[suggestion.notebookID], seen.insert(suggestion.notebookID).inserted else { continue }
            choices.append(Choice(notebookID: suggestion.notebookID, title: title, isSuggested: true))
        }
        let rest = notebooks
            .filter { !seen.contains($0.id) }
            .sorted { lhs, rhs in
                let order = NotebookTitle(lhs.title).text.localizedStandardCompare(NotebookTitle(rhs.title).text)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        for notebook in rest where seen.insert(notebook.id).inserted {
            choices.append(Choice(notebookID: notebook.id, title: notebook.title, isSuggested: false))
        }
        return choices
    }
}
