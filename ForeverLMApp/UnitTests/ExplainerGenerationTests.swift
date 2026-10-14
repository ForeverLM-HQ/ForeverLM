import Foundation
import Testing
@testable import ForeverLM

/// Records what the writer was handed, so the budget and the flag can be pinned.
private final class ExplainerCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [(text: String, truncated: Bool, figureLines: [String])] = []

    var calls: [(text: String, truncated: Bool, figureLines: [String])] {
        lock.lock(); defer { lock.unlock() }
        return storedCalls
    }

    func record(text: String, truncated: Bool, figureLines: [String]) {
        lock.lock(); defer { lock.unlock() }
        storedCalls.append((text, truncated, figureLines))
    }
}

/// A backend that answers with a canned draft, so the storage side of the
/// pipeline can be pinned without a provider.
private struct CannedExplainerBackend: ExplainerModelBackend {
    var draft: ExplainerDraft
    var recorder: ExplainerCallRecorder? = nil

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        recorder?.record(text: text, truncated: truncated, figureLines: figureLines)
        return draft
    }
}

/// A provider that answers after the request was cancelled — a response that
/// was already on the wire when the learner pressed Cancel.
private struct LateExplainerBackend: ExplainerModelBackend {
    var draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        while !Task.isCancelled { await Task.yield() }
        return draft
    }
}

private func makeTemporaryStorage() -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExplainerGenerationTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

private func seedSource(
    _ storage: StorageService,
    url: String,
    title: String,
    type: StudioSourceType,
    content: String?
) async throws -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual)
    article.author = "A. Author"
    if let content {
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
    }
    // A source without text stays queued: the store refuses a ready row that
    // has no durable readable text, which is the case the pipeline must refuse.
    try await storage.saveSource(article)
    return article
}

@Suite("Explainer Generation")
struct ExplainerGenerationTests {

    // MARK: - URL grammar

    @Test("An explainer's URL carries the id of the source it explains, and fixes its own id")
    func urlGrammar() {
        let url = GeneratedExplainer.url(explaining: "abc-123")
        #expect(url == "foreverlm://explainer/abc-123")
        #expect(GeneratedExplainer.isExplainerURL(url))
        #expect(GeneratedExplainer.isExplainerURL("  \(url)\n"))
        #expect(GeneratedExplainer.explainedSourceID(from: url) == "abc-123")
        #expect(GeneratedExplainer.sourceID(explaining: "abc-123") == SourceIdentity.stableID(for: url))
        #expect(GeneratedExplainer.title(for: "  Mitochondria  ") == "Explainer: Mitochondria")

        #expect(!GeneratedExplainer.isExplainerURL("https://example.com/explainer/abc"))
        #expect(!GeneratedExplainer.isExplainerURL("foreverlm://explainer/"))
        #expect(!GeneratedExplainer.isExplainerURL("foreverlm://explainer/a/b"))
        #expect(!GeneratedExplainer.isExplainerURL("foreverlm://course/c/lesson/1"))
        #expect(GeneratedExplainer.explainedSourceID(from: "foreverlm://course/c/lesson/1") == nil)
    }

    @Test("The portable policy and the model agree on the spoken-script prefix")
    func prefixesAgree() {
        #expect(GeneratedExplainer.urlPrefix == TextToSpeechPreparationPolicy.spokenScriptURLPrefix)
        #expect(GeneratedExplainer.urlPrefix == ExplainerScript.urlPrefix)
        #expect(GeneratedExplainer.domain == ExplainerScript.domain)
    }

    @Test("The phone derives the same explainer id the Mac does")
    func explainerIDMatchesThePhone() {
        // `MobileCloudMutationServiceTests.testExplainerIDMatchesTheMac` pins the
        // phone's `MobileCloudMutationService.explainerSourceID(explaining:)` to
        // this same literal: SHA-256 of "source:v1:explainer/abc-123", as both
        // normalizers reduce the URL to "explainer/abc-123". Change one, change both.
        #expect(
            GeneratedExplainer.sourceID(explaining: "abc-123")
                == "src_4ae5c6f243bdc2a50887a7b61658eb97d1465399eed34cec38b2e01b92d2f89a"
        )
        #expect(URLNormalizer.normalize(GeneratedExplainer.url(explaining: "abc-123")) == "explainer/abc-123")
    }

    @Test("The shared core says what can be explained and counts words the way the pipeline stores them")
    func sharedCore() {
        #expect(ExplainerScript.isExplainable(sourceType: "paper", url: "https://j.example/p"))
        #expect(ExplainerScript.isExplainable(sourceType: "article", url: nil))
        #expect(ExplainerScript.isExplainable(sourceType: "podcast", url: "https://p.example/ep"))
        #expect(ExplainerScript.isExplainable(sourceType: "video", url: "https://v.example/w"))
        #expect(ExplainerScript.isExplainable(sourceType: "meeting", url: nil))
        #expect(!ExplainerScript.isExplainable(sourceType: "book", url: "https://b.example"))
        #expect(!ExplainerScript.isExplainable(sourceType: "xPost", url: "https://x.com/a/status/1"))
        #expect(!ExplainerScript.isExplainable(sourceType: "article", url: ExplainerScript.url(explaining: "x")))
        #expect(ExplainerScript.explainableSourceTypeRawValues == Set(GeneratedExplainer.explainableSourceTypes.map(\.rawValue)))
        #expect(ExplainerScript.kindLine("paper") == "paper")
        #expect(ExplainerScript.kindLine("manual") == "article")
        #expect(ExplainerScript.kindLine("podcast") == "podcast episode, read from its transcript")
        #expect(ExplainerScript.wordCount(of: "One two\n\nthree   four.") == 4)
        #expect(ExplainerScript.title(for: " T ") == GeneratedExplainer.title(for: " T "))
    }

    @Test("A spoken script is never sent through the text-to-speech preparation pass")
    func spokenScriptSkipsPreparation() {
        let script = GeneratedExplainer.url(explaining: "x")
        #expect(!TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "article", url: script))
        #expect(!TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "paper", url: script))
        // Every other article, paper, book and course still is.
        #expect(TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "article", url: "https://a.example/b"))
        #expect(TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "paper", url: "https://a.example/p.pdf"))
        #expect(TextToSpeechPreparationPolicy.usesAIPreparation(sourceType: "book", url: "file:///b.pdf"))
    }

    @Test("Explain shows for papers with text, articles and transcribed episodes, videos and meetings, not for explainers or books")
    func canExplain() {
        var article = StudioArticle(url: "https://a.example/b", title: "B", sourceType: .article, discoveryOrigin: .manual)
        article.content = "Some text."
        #expect(GeneratedExplainer.canExplain(article))

        let explainer = StudioArticle(url: GeneratedExplainer.url(explaining: article.id), title: "Explainer: B", sourceType: .article)
        #expect(!GeneratedExplainer.canExplain(explainer))

        let podcast = StudioArticle(url: "https://p.example/ep", title: "Ep", sourceType: .podcast)
        #expect(GeneratedExplainer.canExplain(podcast))

        let book = StudioArticle(url: "file:///b.pdf", title: "Ch 1", sourceType: .book)
        #expect(!GeneratedExplainer.canExplain(book))

        // A paper waiting on its PDF has no text to explain yet.
        let paper = StudioArticle(url: "https://doi.org/10.1/x", title: "P", sourceType: .paper)
        #expect(paper.hasSuccessfulPaperIngestion == false)
        #expect(!GeneratedExplainer.canExplain(paper))
    }

    // MARK: - Pipeline

    @Test("The explainer is saved as an article beside its source, and a second run replaces it")
    func writesAndReplaces() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await seedSource(
            storage, url: "https://journal.example/paper", title: "Deep Breathing", type: .article,
            content: "The full text of the article, long enough to matter."
        )

        let recorder = ExplainerCallRecorder()
        let first = ExplainerGeneratorService(
            storage: storage,
            backend: CannedExplainerBackend(
                draft: ExplainerDraft(title: "Why breathing matters", script: "  Breathing matters because reasons.\n\nSecond paragraph.  "),
                recorder: recorder
            )
        )
        let result = try await first.run(request: ExplainerRequest(sourceID: source.id))
        let explainer = result.explainer

        #expect(!result.replacedExisting)
        #expect(explainer.id == GeneratedExplainer.sourceID(explaining: source.id))
        #expect(explainer.url == GeneratedExplainer.url(explaining: source.id))
        #expect(explainer.sourceType == .article)
        #expect(explainer.title == "Explainer: Deep Breathing")
        #expect(explainer.domain == GeneratedExplainer.domain)
        #expect(explainer.author == "A. Author")
        #expect(explainer.state == .ready)
        #expect(explainer.wordCount == 6)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.text == "The full text of the article, long enough to matter.")
        #expect(recorder.calls.first?.truncated == false)
        // An article has no figures; a paper's come from the index the service was given, and none was.
        #expect(recorder.calls.first?.figureLines == [])

        let stored = try await storage.loadSourceWithoutContent(explainer.id)
        #expect(stored?.title == "Explainer: Deep Breathing")
        let storedScript = await storage.loadSourceContent(explainer.id)
        #expect(storedScript == "Breathing matters because reasons.\n\nSecond paragraph.")
        let sources = try await storage.loadActiveSources()
        #expect(sources.count == 2)

        // Rewriting keeps the same source and moves only its text.
        let second = ExplainerGeneratorService(
            storage: storage,
            backend: CannedExplainerBackend(draft: ExplainerDraft(title: "Again", script: "A new script."))
        )
        let rewrite = try await second.run(request: ExplainerRequest(sourceID: source.id, length: .brief))
        #expect(rewrite.replacedExisting)
        #expect(rewrite.explainer.id == explainer.id)
        let rewritten = await storage.loadSourceContent(explainer.id)
        #expect(rewritten == "A new script.")
        let afterRewrite = try await storage.loadActiveSources()
        #expect(afterRewrite.count == 2)
    }

    @Test("A cancelled run saves nothing, even when the writer answers after the cancel")
    func cancelledRunSavesNothing() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await seedSource(
            storage, url: "https://journal.example/late", title: "Late", type: .article,
            content: "Text enough to explain."
        )

        let service = ExplainerGeneratorService(
            storage: storage,
            backend: LateExplainerBackend(draft: ExplainerDraft(title: "Late", script: "Arrived anyway."))
        )
        let run = Task { try await service.run(request: ExplainerRequest(sourceID: source.id)) }
        await Task.yield()
        run.cancel()
        let outcome = await run.result
        #expect(throws: CancellationError.self) { try outcome.get() }

        let explainerID = GeneratedExplainer.sourceID(explaining: source.id)
        let stored = try await storage.loadSourceWithoutContent(explainerID)
        #expect(stored == nil)
        let sources = try await storage.loadActiveSources()
        #expect(sources.count == 1)
    }

    @Test("An explainer goes with the source it explains")
    func deleteCascade() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await seedSource(
            storage, url: "https://journal.example/paper2", title: "P2", type: .article, content: "Text."
        )
        let service = ExplainerGeneratorService(
            storage: storage,
            backend: CannedExplainerBackend(draft: ExplainerDraft(title: "T", script: "Script."))
        )
        let explainer = try await service.run(request: ExplainerRequest(sourceID: source.id)).explainer
        #expect(try await storage.loadSourceWithoutContent(explainer.id) != nil)

        try await storage.deleteSource(source.id)
        #expect(try await storage.loadSourceWithoutContent(source.id) == nil)
        #expect(try await storage.loadSourceWithoutContent(explainer.id) == nil)
    }

    @Test("The pipeline refuses what it cannot explain, and nothing is written")
    func refusals() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let textless = try await seedSource(
            storage, url: "https://journal.example/none", title: "None", type: .article, content: nil
        )
        // A book's chapters are not explained (podcast episodes are, since 8f34972).
        let book = try await seedSource(
            storage, url: "https://books.example/ch", title: "Ch", type: .book, content: "Chapter."
        )
        let article = try await seedSource(
            storage, url: "https://journal.example/ok", title: "OK", type: .article, content: "Text."
        )
        let good = CannedExplainerBackend(draft: ExplainerDraft(title: "T", script: "Script."))
        let service = ExplainerGeneratorService(storage: storage, backend: good)

        await #expect(throws: ExplainerGenerationError.sourceNotFound("missing")) {
            try await service.run(request: ExplainerRequest(sourceID: "missing"))
        }
        await #expect(throws: ExplainerGenerationError.noText("None")) {
            try await service.run(request: ExplainerRequest(sourceID: textless.id))
        }
        await #expect(throws: ExplainerGenerationError.unsupportedSource("Ch")) {
            try await service.run(request: ExplainerRequest(sourceID: book.id))
        }

        let explainer = try await service.run(request: ExplainerRequest(sourceID: article.id)).explainer
        await #expect(throws: ExplainerGenerationError.unsupportedSource(explainer.title)) {
            try await service.run(request: ExplainerRequest(sourceID: explainer.id))
        }

        let empty = ExplainerGeneratorService(
            storage: storage,
            backend: CannedExplainerBackend(draft: ExplainerDraft(title: "T", script: "   \n"))
        )
        await #expect(throws: ExplainerGenerationError.emptyScript) {
            try await empty.run(request: ExplainerRequest(sourceID: article.id))
        }
        // The failed rewrite left the earlier explainer as it was.
        let kept = await storage.loadSourceContent(explainer.id)
        #expect(kept == "Script.")
        let sources = try await storage.loadActiveSources()
        #expect(sources.count == 4)
    }

    // MARK: - The writer's turn

    @Test("A long text is cut to the budget and the writer is told")
    func budget() {
        let long = String(repeating: "a", count: ExplainerGeneratorService.sourceCharacterBudget + 1)
        let cut = ExplainerGeneratorService.budgeted(long)
        #expect(cut.truncated)
        #expect(cut.text.count == ExplainerGeneratorService.sourceCharacterBudget)

        let short = ExplainerGeneratorService.budgeted("short")
        #expect(!short.truncated)
        #expect(short.text == "short")

        var source = StudioArticle(url: "https://j.example/p", title: "Paper", sourceType: .paper, discoveryOrigin: .manual)
        source.author = "Ada Lovelace"
        source.journal = "Nature"
        source.publishedYear = "2026"
        let message = AIService.explainerUserMessage(source: source, text: cut.text, truncated: true, length: .standard)
        #expect(message.hasPrefix("Source: Paper\nKind: paper\nAuthors: Ada Lovelace\nPublished: Nature, 2026\n"))
        #expect(message.contains("Target length: 900 to 1200 words, about seven minutes spoken."))
        #expect(message.contains("the rest was cut"))
        #expect(!message.contains("Full text:"))

        let whole = AIService.explainerUserMessage(source: source, text: "Body.", truncated: false, length: .extended)
        #expect(whole.contains("Target length: 1500 to 1900 words, about twelve minutes spoken."))
        #expect(whole.hasSuffix("Full text:\nBody."))

        // The phone builds the turn from the same fields through the shared
        // core, so the two apps' writers see byte-identical prompts.
        let shared = ExplainerScript.writerUserMessage(
            title: source.title,
            sourceType: "paper",
            author: source.author,
            journal: source.journal,
            publishedYear: source.publishedYear,
            text: "Body.",
            truncated: false,
            length: .extended
        )
        #expect(shared == whole)
    }

    @Test("A paper's figures are listed before its text in the writer's turn, in the walkthrough writer's lines, and a turn without figures is unchanged")
    func writerTurnFigures() {
        let source = StudioArticle(url: "https://j.example/p", title: "Paper", sourceType: .paper, discoveryOrigin: .manual)
        var figure = PaperWalkthroughFigureReference(
            label: "Figure 1", pageNumber: 2,
            caption: "Fig. 1 | Intracellular Na elevation and contractility.",
            panelLabels: ["a", "b"]
        )
        figure.printedText = ["LVDP (mmHg)", "Time (min)"]
        figure.reading = "Sodium rises under ouabain and returns after washout."
        let lines = PaperWalkthroughGeneratorService.figureLines([figure])
        #expect(lines == ["- Figure 1 · page 2 · Fig. 1 | Intracellular Na elevation and contractility. · panels: a, b · printed in the figure: LVDP (mmHg); Time (min) · seen: Sodium rises under ouabain and returns after washout."])

        let with = AIService.explainerUserMessage(source: source, text: "Body.", truncated: false, length: .standard, figureLines: lines)
        #expect(with.contains("\nFigures printed in the paper (label · page · caption"))
        #expect(with.hasSuffix("The script goes through them:\n\(lines[0])\n\nFull text:\nBody."))

        // The phone passes no lines, and its turn is the Mac's for a paper whose figures could not be read.
        let without = AIService.explainerUserMessage(source: source, text: "Body.", truncated: false, length: .standard)
        #expect(!without.contains("Figures printed"))
        #expect(without == ExplainerScript.writerUserMessage(
            title: "Paper", sourceType: "paper", author: nil, journal: nil, publishedYear: nil,
            text: "Body.", truncated: false, length: .standard
        ))
        #expect(Prompts.explainerWriter.contains("the findings are told through them"))
    }

    @Test("Explainer Writing is a Settings task with the writer's prompt, and the MCP tool is registered")
    func taskAndTool() {
        #expect(AITask.explainerWriting.rawValue == "explainer_writing")
        #expect(AITask.explainerWriting.defaultPrompt == Prompts.explainerWriter)
        #expect(AITask.explainerWriting.sourceType == nil)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "explainer_writing")?.displayName == "Explainer Writing")

        let tool = MCPToolRegistry.shared.tools.first { $0.name == "generate_explainer" }
        #expect(tool != nil)
        #expect((tool?.inputSchema["required"] as? [String]) == ["source_id"])
        let properties = tool?.inputSchema["properties"] as? [String: Any]
        // approved_spend_usd is the paid-work ceiling every paid tool takes
        // since 96478bb01.
        #expect(Set(properties?.keys.map { $0 } ?? []) == ["source_id", "length", "generate_audio", "confirm_cost", "approved_spend_usd"])
    }

    @Test("The Reader's masthead drops the list prefix and states the length in words and minutes")
    func mastheadWording() {
        #expect(GeneratedExplainer.displayTitle(for: "Explainer: Overview of methods") == "Overview of methods")
        #expect(GeneratedExplainer.displayTitle(for: "  Explainer:   Spaced  ") == "Spaced")
        // A renamed explainer, or a bare prefix, is shown as it stands.
        #expect(GeneratedExplainer.displayTitle(for: "My own title") == "My own title")
        #expect(GeneratedExplainer.displayTitle(for: "Explainer:") == "Explainer:")

        #expect(GeneratedExplainer.listeningTimeLabel(wordCount: 0) == "under a minute")
        #expect(GeneratedExplainer.listeningTimeLabel(wordCount: 60) == "under a minute")
        #expect(GeneratedExplainer.listeningTimeLabel(wordCount: 150) == "about a minute")
        #expect(GeneratedExplainer.listeningTimeLabel(wordCount: 1_050) == "about 7 minutes")
        // The standard length's midpoint lands on the time ExplainerLength promises.
        let standard = ExplainerLength.standard.wordRange
        let midpoint = (standard.lowerBound + standard.upperBound) / 2
        #expect(GeneratedExplainer.listeningTimeLabel(wordCount: midpoint) == "about 7 minutes")
        #expect(GeneratedExplainer.lengthLabel(wordCount: 1_050).hasSuffix("words · about 7 minutes to listen"))
    }
}
