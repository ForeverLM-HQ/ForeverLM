import Foundation
import Testing
@testable import ForeverLM

/// The matching call's request and response shapes. Identity never reaches
/// the model: articles and Notebooks travel under opaque handles, and a verdict
/// naming a handle that was not sent is dropped rather than guessed at.
@Suite("Journal article matching")
struct JournalArticleMatchingTests {

    private static let notebooks = [
        JournalMatchingNotebook(
            id: "notebook-mito",
            title: "Mitochondria in ageing",
            instructions: "Track mitochondrial quality control in aged tissue.",
            researchQuestions: ["Does mitophagy decline with age?", ""],
            topic: "mitochondria",
            sampleSourceTitles: ["PINK1 and Parkin in muscle", "Cristae remodelling"]
        ),
        JournalMatchingNotebook(id: "notebook-app", title: "ForeverLM roadmap", instructions: nil, researchQuestions: [], topic: nil, sampleSourceTitles: []),
    ]

    private static let candidates = [
        JournalMatchingCandidate(id: "https://www.nature.com/articles/a1", title: "Cristae dynamics in old hearts", summary: "OPA1 …", source: "Nature", authors: "X, Y"),
        JournalMatchingCandidate(id: "https://www.nature.com/articles/a2", title: "Author Correction: quantum dots", summary: nil, source: nil, authors: nil),
        JournalMatchingCandidate(id: "https://www.astralcodexten.com/p/mito", title: "What the new mitophagy paper actually shows", summary: "A close read.", source: "Astral Codex Ten", authors: "Scott Alexander"),
    ]

    @Test("The request carries handles, never ids, and every field the model needs")
    func request() {
        let request = AIService.journalMatchingRequest(notebooks: Self.notebooks, candidates: Self.candidates)
        #expect(request.notebookHandles == ["p1": "notebook-mito", "p2": "notebook-app"])
        #expect(request.articleHandles == ["a1": "https://www.nature.com/articles/a1", "a2": "https://www.nature.com/articles/a2", "a3": "https://www.astralcodexten.com/p/mito"])
        #expect(!request.userMessage.contains("notebook-mito"), "Notebook ids stay out of the prompt")
        #expect(!request.userMessage.contains("nature.com"), "article URLs stay out of the prompt")
        #expect(!request.userMessage.contains("astralcodexten.com"), "blog URLs stay out of the prompt too")
        #expect(request.userMessage.contains("\"source\":\"Astral Codex Ten\""), "a blog post names its blog the way a paper names its journal")
        #expect(request.userMessage.contains("\"research_questions\":[\"Does mitophagy decline with age?\"]"), "empty questions are dropped")
        #expect(request.userMessage.contains("\"existing_sources\":[\"PINK1 and Parkin in muscle\",\"Cristae remodelling\"]"))
        #expect(request.userMessage.contains("\"topic\":\"mitochondria\""))
        #expect(!request.userMessage.contains("\"topic\":\"ForeverLM roadmap\""), "a topic equal to the title is not repeated")
        #expect(request.userMessage.contains("\"source\":\"Nature\""))
        #expect(request.userMessage.contains("\"id\":\"a2\",\"title\":\"Author Correction: quantum dots\"}"), "absent fields are omitted, not sent empty")
    }

    @Test("Verdicts map back through the handles; unknown handles and duplicates are dropped")
    func response() throws {
        let request = AIService.journalMatchingRequest(notebooks: Self.notebooks, candidates: Self.candidates)
        let response = """
        Here you go:
        {"matches": [
          {"article": "a1", "notebook": "p1", "reason": "Cristae remodelling in aged cardiomyocytes is the Notebook's question."},
          {"article": "a1", "notebook": "p1", "reason": "duplicate"},
          {"article": "a9", "notebook": "p1", "reason": "never sent"},
          {"article": "a2", "notebook": "p7", "reason": "never sent either"},
          {"article": "a2", "notebook": "p2"}
        ]}
        """
        let verdicts = try AIService.parseJournalMatchingResponse(
            response, articleHandles: request.articleHandles, notebookHandles: request.notebookHandles
        )
        #expect(verdicts == [
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/a1", notebookID: "notebook-mito", reason: "Cristae remodelling in aged cardiomyocytes is the Notebook's question."),
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/a2", notebookID: "notebook-app", reason: ""),
        ])
    }

    @Test("An empty match list is a valid answer; prose without JSON is not")
    func emptyAndMalformed() throws {
        let request = AIService.journalMatchingRequest(notebooks: Self.notebooks, candidates: Self.candidates)
        #expect(try AIService.parseJournalMatchingResponse("{\"matches\": []}", articleHandles: request.articleHandles, notebookHandles: request.notebookHandles).isEmpty)
        #expect(throws: AIError.self) {
            _ = try AIService.parseJournalMatchingResponse("Nothing matches this week.", articleHandles: request.articleHandles, notebookHandles: request.notebookHandles)
        }
        #expect(throws: AIError.self) {
            _ = try AIService.parseJournalMatchingResponse("{\"verdicts\": []}", articleHandles: request.articleHandles, notebookHandles: request.notebookHandles)
        }
    }

    @Test("The task is registered everywhere a task must be")
    func registration() {
        #expect(AITask.journalArticleMatching.rawValue == "journal_article_matching")
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "journal_article_matching")?.displayName == "Feed Article Matching")
        #expect(AITask.journalArticleMatching.usesBackgroundModelDefault)
        #expect(!AITask.journalArticleMatching.requiresVision)
        #expect(AITask.journalArticleMatching.sourceType == .paper)
        #expect(AITask.journalArticleMatching.defaultPrompt == Prompts.journalArticleMatching)
    }
}
