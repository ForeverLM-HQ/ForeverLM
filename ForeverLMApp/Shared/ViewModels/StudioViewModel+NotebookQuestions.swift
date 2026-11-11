import Foundation

// MARK: - A notebook's kept suggested questions
//
// The guide's questions, kept per notebook once suggested
// (`NotebookSuggestedQuestions`; docs/notebooks-design.md, "The notebook
// guide"): the rows' reads and writes on the Mac, and the view model's three
// verbs the chat calls — what to offer, keep what an answer suggested, and
// remember a question asked.

/// The Mac's reads and writes of the `notebook.questions.<notebookID>` rows.
enum NotebookSuggestedQuestionRows {
    /// A test's own defaults, bound for the task that runs it (as
    /// `NotebookNamingRows.overrideDefaults`). While bound, writes go to the
    /// suite and never to the sync rail.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    static func kept(notebookID: String) -> NotebookSuggestedQuestions.Kept? {
        NotebookSuggestedQuestions.Kept.decoded(
            defaults.object(forKey: Prefs.Families.notebookQuestions.name(notebookID))
        )
    }

    static func setKept(_ kept: NotebookSuggestedQuestions.Kept, notebookID: String) {
        let key = Prefs.Families.notebookQuestions.key(notebookID)
        if let override = overrideDefaults {
            override.defaults.set(kept.encoded, forKey: key.name)
            return
        }
        // `PreferenceStore` drops a write that changes nothing.
        Preferences.set(kept.encoded, for: key)
    }
}

extension StudioViewModel {
    /// The notebook's sources as the kept questions were suggested for them:
    /// its own sources, named as the library names them, whatever is ticked.
    func notebookQuestionsFingerprint(_ notebook: LearningGoalRecord) -> String {
        NotebookSuggestedQuestions.fingerprint(of: notebookOutputMemberIDs(notebook))
    }

    /// What the notebook's guide offers: the Suggest questions chip, the kept
    /// questions not asked yet, or — every one asked and its sources
    /// unchanged — nothing more. Reads this Mac's defaults; no model call.
    func notebookQuestionOffer(_ notebook: LearningGoalRecord) -> NotebookSuggestedQuestions.Offer {
        NotebookSuggestedQuestions.offer(
            NotebookSuggestedQuestionRows.kept(notebookID: notebook.id),
            sourcesFingerprint: notebookQuestionsFingerprint(notebook)
        )
    }

    /// Keeps the questions a Suggest questions answer suggested for the
    /// notebook as its sources stand now.
    func keepNotebookQuestions(_ questions: [String], notebook: LearningGoalRecord) {
        guard let kept = NotebookSuggestedQuestions.keeping(
            questions,
            sourcesFingerprint: notebookQuestionsFingerprint(notebook),
            previous: NotebookSuggestedQuestionRows.kept(notebookID: notebook.id)
        ) else { return }
        NotebookSuggestedQuestionRows.setKept(kept, notebookID: notebook.id)
    }

    /// Remembers that `question` was asked in one of the notebook's chats, so
    /// the guide never offers it again; a question it never suggested
    /// changes nothing.
    func noteNotebookQuestionAsked(_ question: String, notebookID: String) {
        guard let kept = NotebookSuggestedQuestions.asking(
            question,
            in: NotebookSuggestedQuestionRows.kept(notebookID: notebookID)
        ) else { return }
        NotebookSuggestedQuestionRows.setKept(kept, notebookID: notebookID)
    }
}
