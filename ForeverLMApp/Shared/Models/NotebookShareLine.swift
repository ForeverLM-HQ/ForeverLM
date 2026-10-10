import Foundation

/// What a notebook's Share says on the Mac and the iPhone, which compile this
/// one file, and on the web, which says the same (`notebookShareTitle`,
/// `notebookShareLine` in library-sharing.js; its test reads these words from
/// here): the title, and the one line on what a share gives, before the
/// notebook is shared and after (docs/teams-design.md, decision 22). The
/// count is the notebook's approved sources, the ones a share carries into a
/// team (`LearningGoalRecord.approvedSourceIDs`), on every client.
enum NotebookShareLine {
    /// "Share Bioelectricity", or "Share Notebook" for a notebook with no title.
    static func title(notebookTitle: String) -> String {
        let title = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Share Notebook" : "Share \(title)"
    }

    /// "Shares the notebook and its 43 sources", its digits grouped.
    static func text(sourceCount: Int) -> String {
        switch sourceCount {
        case ..<1: return "Shares the notebook"
        case 1: return "Shares the notebook and its source"
        default: return "Shares the notebook and its \(sourceCount.formatted()) sources"
        }
    }
}
