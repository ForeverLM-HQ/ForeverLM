import Foundation
import Testing
@testable import ForeverLM

/// A notebook's suggested questions, kept once suggested
/// (`NotebookSuggestedQuestions`; docs/notebooks-design.md, "The notebook
/// guide"): what the guide offers, what an answer's questions keep, and a
/// question asked never offered again.
@Suite("Notebook suggested questions")
struct NotebookSuggestedQuestionsTests {
    private let sources = NotebookSuggestedQuestions.fingerprint(of: ["s2", "s1"])

    @Test("The fingerprint is the set of sources: order and repeats do not change it, another source does")
    func fingerprint() {
        #expect(NotebookSuggestedQuestions.fingerprint(of: ["s1", "s2", "s1"]) == sources)
        #expect(NotebookSuggestedQuestions.fingerprint(of: ["s1", "s2", "s3"]) != sources)
        #expect(sources.count == 24)
    }

    @Test("Nothing kept for these sources offers the chip; kept questions are offered until each is asked; then nothing until the sources change")
    func offers() throws {
        #expect(NotebookSuggestedQuestions.offer(nil, sourcesFingerprint: sources) == .suggest)
        let kept = try #require(NotebookSuggestedQuestions.keeping(
            ["What is ATP synthase?", "  ", "what is ATP synthase", "How do cristae form?"],
            sourcesFingerprint: sources, previous: nil
        ))
        #expect(kept.questions == ["What is ATP synthase?", "How do cristae form?"], "blank and folded repeats dropped")
        #expect(NotebookSuggestedQuestions.offer(kept, sourcesFingerprint: sources) == .questions(["What is ATP synthase?", "How do cristae form?"]))

        let once = try #require(NotebookSuggestedQuestions.asking("what is atp synthase", in: kept))
        #expect(NotebookSuggestedQuestions.offer(once, sourcesFingerprint: sources) == .questions(["How do cristae form?"]))
        #expect(NotebookSuggestedQuestions.asking("What is ATP synthase?", in: once) == nil, "asked once is remembered once")
        #expect(NotebookSuggestedQuestions.asking("Something it never suggested", in: once) == nil)

        let both = try #require(NotebookSuggestedQuestions.asking("How do cristae form?", in: once))
        #expect(NotebookSuggestedQuestions.offer(both, sourcesFingerprint: sources) == .askedAll)
        let changed = NotebookSuggestedQuestions.fingerprint(of: ["s1", "s2", "s3"])
        #expect(NotebookSuggestedQuestions.offer(both, sourcesFingerprint: changed) == .suggest, "new sources, new questions")
    }

    @Test("New questions replace the kept ones and never bring back one already asked")
    func newSuggestionsKeepWhatWasAsked() throws {
        let kept = try #require(NotebookSuggestedQuestions.keeping(["A?", "B?"], sourcesFingerprint: sources, previous: nil))
        let asked = try #require(NotebookSuggestedQuestions.asking("A?", in: kept))
        let changed = NotebookSuggestedQuestions.fingerprint(of: ["s3"])
        let next = try #require(NotebookSuggestedQuestions.keeping(["a", "C?"], sourcesFingerprint: changed, previous: asked))
        #expect(next.sources == changed)
        #expect(next.questions == ["C?"])
        #expect(next.asked == ["A?"])
        #expect(NotebookSuggestedQuestions.keeping([], sourcesFingerprint: sources, previous: nil) == nil)
        let many = (1...10).map { "Q\($0)?" }
        #expect(NotebookSuggestedQuestions.keeping(many, sourcesFingerprint: sources, previous: nil)?.questions.count
            == NotebookSuggestedQuestions.maximumQuestions)
    }

    @Test("The row is a JSON string every client reads; anything else reads as no row")
    func rowFormat() throws {
        let kept = NotebookSuggestedQuestions.Kept(sources: sources, questions: ["A?"], asked: [])
        #expect(kept.encoded == #"{"asked":[],"questions":["A?"],"sources":"\#(sources)"}"#)
        #expect(NotebookSuggestedQuestions.Kept.decoded(kept.encoded) == kept)
        #expect(NotebookSuggestedQuestions.Kept.decoded(3) == nil)
        #expect(NotebookSuggestedQuestions.Kept.decoded(#"{"asked":[],"questions":[],"sources":""}"#) == nil)
        #expect(NotebookSuggestedQuestions.preferenceKey(notebookID: "nb") == "notebook.questions.nb")
    }

    @Test("The row is a synced preference, left out of the settings catalog's set_app_setting")
    func rowSyncs() {
        #expect(SyncedPreferenceKeys.isSynced("notebook.questions.nb"))
        #expect(SyncedPreferenceKeys.isSetting("notebook.questions.nb"))
    }

    @Test("Rows are read and written through the defaults a test binds")
    func rows() throws {
        let suite = "NotebookSuggestedQuestionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        NotebookSuggestedQuestionRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            #expect(NotebookSuggestedQuestionRows.kept(notebookID: "nb") == nil)
            let kept = NotebookSuggestedQuestions.Kept(sources: sources, questions: ["A?"], asked: [])
            NotebookSuggestedQuestionRows.setKept(kept, notebookID: "nb")
            #expect(NotebookSuggestedQuestionRows.kept(notebookID: "nb") == kept)
            #expect(defaults.string(forKey: "notebook.questions.nb") == kept.encoded)
        }
    }
}
