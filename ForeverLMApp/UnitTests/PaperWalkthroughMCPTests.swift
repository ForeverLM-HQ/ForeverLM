// Walkthrough subject, figure index, MCP tool, video and animation walkthrough tests.

import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

private func makeTemporaryStorage(_ name: String) -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaperWalkthroughTests_\(name)_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

// MARK: - Subject

/// What a walkthrough may be written about, and with which anchors (product owner,
/// 2026-09-19: "books (or chapters thereof) and articles").
@Suite("Walkthrough subject")
struct PaperWalkthroughSubjectTests {

    private func source(_ type: StudioSourceType, url: String = "https://example.com/s", file: String? = nil, state: StudioArticleState = .ready) -> StudioArticle {
        var article = StudioArticle(url: url, title: "S", sourceType: type, discoveryOrigin: .manual, localFilePath: file)
        article.state = state
        return article
    }

    @Test("A paper, a book chapter and an article are subjects; a podcast, a video and an explainer's page are not")
    func subjects() {
        #expect(PaperWalkthroughSubject.of(source(.paper)) == .paper)
        #expect(PaperWalkthroughSubject.of(source(.book, file: "Books/B/Chapters/01.pdf")) == .chapter)
        #expect(PaperWalkthroughSubject.of(source(.article)) == .article)
        #expect(PaperWalkthroughSubject.of(source(.podcast)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.video)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.meeting)) == nil)
        #expect(PaperWalkthroughSubject.of(source(.article, url: GeneratedExplainer.url(explaining: "abc"))) == nil)
        #expect(PaperWalkthroughSubject.paper.noun == "paper")
        #expect(PaperWalkthroughSubject.chapter.noun == "chapter")
        #expect(PaperWalkthroughSubject.article.noun == "article")
    }

    @Test("Figures may be anchored on a paper and a PDF chapter; never on an article or an EPUB chapter")
    func figureAnchors() {
        #expect(PaperWalkthroughSubject.allowsFigureAnchors(source(.paper)))
        #expect(PaperWalkthroughSubject.allowsFigureAnchors(source(.book, file: "Books/B/Chapters/01.pdf")))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.book, file: "Books/B/Chapters/01.xhtml")))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.article)))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(source(.podcast)))
    }

    @Test("The readiness gate is the paper's ingestion gate, and a chapter's or an article's ready state")
    func readiness() {
        // A paper is ready only after its metadata and cleanup stages; a bare
        // ready paper has neither.
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.paper)))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.article)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.article, state: .queued)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.article, state: .error)))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.pdf")))
        #expect(PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.xhtml")))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.book, file: "Books/B/Chapters/01.pdf", state: .fetching)))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(source(.podcast)))
    }

    @Test("The writer's turn names the subject and, for a text source, says there is nothing to outline")
    func writerTurnPerSubject() {
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, discoveryOrigin: .manual)
        article.domain = "example.com"
        let articleTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: article, text: "TEXT", truncated: false, figures: figures)
        #expect(articleTurn.hasPrefix("Article: A post\nSite: example.com"))
        #expect(articleTurn.contains("shown as text, not as a PDF"))
        #expect(articleTurn.contains("Write no step of kind \"figure\""))
        #expect(!articleTurn.contains("Figures printed"), "an article is offered no figure list even when one is passed")

        let chapter = StudioArticle(url: "Books/Sleep/Chapters/03.pdf", title: "Chapter 3", sourceType: .book, discoveryOrigin: .manual, parentGroup: "Sleep", localFilePath: "Books/Sleep/Chapters/03.pdf")
        let chapterTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: chapter, text: "TEXT", truncated: false, figures: figures)
        #expect(chapterTurn.hasPrefix("Chapter: Chapter 3\nBook: Sleep"))
        #expect(chapterTurn.contains("Figures printed in the paper"))
        #expect(chapterTurn.contains("- Figure 2 · page 4"))

        let epub = StudioArticle(url: "Books/Sleep/Chapters/03.xhtml", title: "Chapter 3", sourceType: .book, discoveryOrigin: .manual, parentGroup: "Sleep", localFilePath: "Books/Sleep/Chapters/03.xhtml")
        let epubTurn = PaperWalkthroughGeneratorService.writerUserMessage(source: epub, text: "TEXT", truncated: false, figures: [])
        #expect(epubTurn.contains("this chapter is shown as text"))

        let paper = StudioArticle(url: "https://example.com/p", title: "Sleep paper", sourceType: .paper)
        #expect(PaperWalkthroughGeneratorService.writerUserMessage(source: paper, text: "TEXT", truncated: false, figures: figures).hasPrefix("Paper: Sleep paper"))
    }

    @Test("A figure anchor on a text source is refused by name and the step explains instead; its passage is kept")
    func validatorRefusesFiguresOnTextSource() throws {
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk",
            steps: [
                step(.figure, title: "The model", figure: "Figure 2", passage: "Figure 2 shows the mitochondrial electron surplus model"),
                step(.explain, title: "Plain", passage: "Sleep pressure rises during waking"),
            ],
            sourceID: "src",
            sourceSHA256: "sha",
            figures: figures,
            allowsFigureAnchors: false,
            text: paperText,
            author: .assistant
        )
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("Figure 2"))
        #expect(outcome.warnings[0].contains("shown as text and has no figures to outline"))
        #expect(outcome.walkthrough.steps[0].kind == .explain)
        #expect(outcome.walkthrough.steps[0].anchor?.figureLabel == nil)
        #expect(outcome.walkthrough.steps[0].anchor?.passage?.hasPrefix("Figure 2 shows") == true)
        #expect(outcome.walkthrough.steps[1].anchor?.passage == "Sleep pressure rises during waking")
    }
}

// MARK: - Figure index for chapters

/// A chapter split from a PDF enters the figure index the way a paper does;
/// an EPUB chapter's text file does not.
@Suite("Walkthrough figure index for chapters")
struct PaperWalkthroughFigureIndexTests {

    @Test("A PDF chapter is queued and found as an index candidate and target; an EPUB chapter is not")
    func chapterEntersFigureIndex() async throws {
        let (storage, root) = makeTemporaryStorage("figure-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfChapter = try await seedChapter(storage, file: "Books/Sleep/Chapters/03.pdf", content: paperText)
        let epubChapter = try await seedChapter(storage, file: "Books/Sleep/Chapters/04.xhtml", title: "Chapter 4", content: paperText)
        let store = try KnowledgeStore(storeDirectory: root)

        try store.ensurePaperFigureIndexQueuedForReview(sourceID: pdfChapter.id, force: false)
        let candidate = try #require(try store.paperFigureIndexCandidate(sourceID: pdfChapter.id))
        #expect(candidate.title == "Chapter 3")
        #expect(candidate.pdfPath.hasSuffix("Books/Sleep/Chapters/03.pdf"))
        #expect(try store.nextPaperFigureIndexCandidate()?.sourceID == pdfChapter.id)
        let target = try #require(try store.paperFigureIndexTarget(sourceID: pdfChapter.id))
        #expect(target.pdfPath.hasSuffix("Books/Sleep/Chapters/03.pdf"))

        try store.ensurePaperFigureIndexQueuedForReview(sourceID: epubChapter.id, force: false)
        #expect(try store.paperFigureIndexCandidate(sourceID: epubChapter.id) == nil)
    }
}

// MARK: - MCP

/// The four tools on a source that is not a paper (walkthrough-design.md,
/// "Books (or chapters thereof) and articles").
@Suite("MCP walkthrough tools")
struct MCPWalkthroughToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func seed(_ store: MCPDataStore, type: StudioSourceType, url: String, title: String, file: String? = nil, group: String? = nil) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual, parentGroup: group, localFilePath: file)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.domain = "example.com"
        article.author = "A. Author"
        article.content = paperText
        article.state = .ready
        try store.knowledgeStore().saveSource(article)
        return article
    }

    private let steps: [[String: Any]] = [
        ["kind": "explain", "title": "Start", "body": "Read this first.", "passage": "Sleep pressure rises during waking"],
        ["kind": "figure", "title": "The model", "body": "Look here.", "figure_label": "Figure 2"],
        ["kind": "quiz", "title": "Check", "body": "One question.", "quiz": ["question": "What rose?", "answer": "ATP rose about 1.2 times after sleep deprivation.", "key_points": ["ATP", "higher after deprivation"]]],
    ]

    @Test("save_walkthrough on an article refuses the figure anchor by name, keeps the passage, and get, then delete, read it back")
    func articleRoundTrip() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seed(store, type: .article, url: "https://example.com/post", title: "A post")

        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "article")
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect((saved["figures_available"] as? [[String: Any]])?.isEmpty == true)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("Figure 2") && warnings[0].contains("shown as text"))
        #expect((saved["message"] as? String)?.contains("beside the article") == true)

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        #expect(got["status"] as? String == "ok")
        #expect(got["subject"] as? String == "article")
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        #expect(gotSteps.map { $0["kind"] as? String } == ["explain", "explain", "quiz"])
        #expect((gotSteps[0]["anchor"] as? [String: Any])?["passage"] as? String == "Sleep pressure rises during waking")
        #expect(gotSteps[1]["anchor"] == nil)

        let deleted = try parseJSON(try await store.deleteWalkthrough(arguments: ["source_id": article.id]))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("article's walkthrough") == true)
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["figure_anchors"] as? Bool == false)
    }

    @Test("list_walkthroughs names every walk with its source, counts and status, and is empty until one is saved")
    func listTool() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let empty = try parseJSON(try await store.listWalkthroughs())
        #expect(empty["count"] as? Int == 0)
        #expect((empty["walkthroughs"] as? [[String: Any]])?.isEmpty == true)

        let article = try seed(store, type: .article, url: "https://example.com/post", title: "A post")
        _ = try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps])
        let listed = try parseJSON(try await store.listWalkthroughs())
        #expect(listed["count"] as? Int == 1)
        let entry = try #require((listed["walkthroughs"] as? [[String: Any]])?.first)
        #expect(entry["source_id"] as? String == article.id)
        #expect(entry["source_title"] as? String == "A post")
        #expect(entry["subject"] as? String == "article")
        #expect(entry["title"] as? String == "Walk")
        #expect(entry["status"] as? String == "ok")
        #expect(entry["author"] as? String == "assistant")
        #expect(entry["step_count"] as? Int == 3)
        // "Read this first." and "Look here." are a card each; the quiz is one.
        #expect(entry["card_count"] as? Int == 3)
        #expect(entry["quiz_count"] as? Int == 1)
        #expect(entry["figure_step_count"] as? Int == 0)
    }

    @Test("save_walkthrough on a PDF chapter takes figure anchors; a chapter whose PDF is unread keeps the words and names the index")
    func chapterSave() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let chapter = try seed(store, type: .book, url: "Books/Sleep/Chapters/03.pdf", title: "Chapter 3", file: "Books/Sleep/Chapters/03.pdf", group: "Sleep")

        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": chapter.id, "title": "Chapter walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "chapter")
        #expect(saved["figure_anchors"] as? Bool == true)
        let warnings = try #require(saved["warnings"] as? [String])
        // No PDF on disk, so the index is empty: the figure is "not in the
        // index", never "this source has no figures".
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("figure index does not have"))
        #expect((saved["message"] as? String)?.contains("beside the chapter") == true)
    }

    @Test("A podcast is refused with the qualifying kinds named, and generate_walkthrough refuses a source that is not ready")
    func refusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let podcast = try seed(store, type: .podcast, url: "https://example.com/episode", title: "An episode")
        await #expect(throws: MCPError.self) {
            try await store.saveWalkthrough(arguments: ["source_id": podcast.id, "title": "Walk", "steps": steps])
        }
        await #expect(throws: MCPError.self) {
            try await store.generateWalkthrough(arguments: ["source_id": podcast.id])
        }
        do {
            _ = try await store.saveWalkthrough(arguments: ["source_id": podcast.id, "title": "Walk", "steps": steps])
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains(PaperWalkthroughSubject.savableQualifyingPhrase))
        }
    }

    @Test("save_walkthrough keeps a step's cited works, checks a library id, and get_walkthrough says which the library holds")
    func citedWorksRoundTrip() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seed(store, type: .article, url: "https://example.com/letter", title: "A letter")
        let held = try seed(store, type: .article, url: "https://example.com/held-essay", title: "The held essay")
        var cited = steps
        cited[0]["cites"] = [
            ["title": "The Abstraction Fallacy", "authors": ["Alexander Lerchner"], "year": 2026, "kind": "paper", "url": "https://example.org/abstraction-fallacy"],
            ["title": "The held essay", "url": "foreverlm://source/\(held.id)"],
            ["title": "An essay the library lost", "source_id": "src_not_in_this_library", "kind": "treatise"],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": cited]))
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("src_not_in_this_library") && $0.contains("does not hold") })
        #expect(warnings.contains { $0.contains("kind treatise") })

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        let cites = try #require(gotSteps[0]["cites"] as? [[String: Any]])
        #expect(cites.map { $0["title"] as? String } == ["The Abstraction Fallacy", "The held essay", "An essay the library lost"])
        #expect(cites[0]["authors"] as? String == "Alexander Lerchner")
        #expect(cites[0]["year"] as? String == "2026")
        #expect(cites[0]["kind"] as? String == "paper")
        #expect(cites[0]["in_library"] as? Bool == false)
        #expect(cites[1]["in_library"] as? Bool == true)
        #expect(cites[1]["source_id"] as? String == held.id)
        #expect(cites[2]["source_id"] == nil)
        #expect(cites[2]["kind"] == nil)
        #expect(gotSteps[1]["cites"] == nil)
    }
}

// MARK: - Video walkthroughs

/// A talk as the importer stores one: timed transcript blocks, then the block
/// its captured slides add.
private let talkTranscript = """
[0:00] Welcome to Agential Topics. Today we look at the cristae of the inner mitochondrial membrane.

[0:42] The folds are not random. Their curvature concentrates the proton motive force along the ridge.

[1:30] So the geometry itself does electrical work, which is the claim of this talk.
"""

private let talkSlides = """
\(SlideFrameExtraction.slideSectionHeader)

Representative slide screenshots extracted from this video's frames.

### Slide frame 1 [0:40–1:25]
Image: Videos/59GAgPbcQVg/slide_001.jpg
"""

/// A YouTube video's walk (walkthrough-design.md, "2026-09-29: a video is
/// walked through at its moments"): its steps point at moments of the talk,
/// the Reader holds the player there, and only an assistant writes one.
@Suite("Video walkthroughs")
struct VideoWalkthroughTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_video_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: tmpDir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func video(url: String = "https://www.youtube.com/watch?v=59GAgPbcQVg", content: String = talkTranscript + "\n\n" + talkSlides) -> StudioArticle {
        var video = StudioArticle(url: url, title: "Finbow's cristae", sourceType: .video, discoveryOrigin: .manual)
        video.normalizedURL = URLNormalizer.normalize(url)
        video.content = content
        video.state = .ready
        return video
    }

    @Test("A YouTube video is a subject the Reader plays and the writer leaves to an assistant; another site's video is none")
    func subject() {
        let youTube = video()
        #expect(PaperWalkthroughSubject.of(youTube) == .video)
        #expect(PaperWalkthroughGeneratorService.canPlayWalkthrough(youTube))
        #expect(!PaperWalkthroughGeneratorService.canWalkThrough(youTube))
        #expect(!PaperWalkthroughSubject.allowsFigureAnchors(youTube))
        #expect(PaperWalkthroughSubject.video.allowsMomentAnchors)
        #expect(!PaperWalkthroughSubject.video.writerWrites)
        #expect(PaperWalkthroughSubject.of(video(url: "https://vimeo.com/123456")) == nil)
    }

    @Test("A video's walk is of its talk: the slide block is left out of the text it is held to, and capturing slides leaves it current")
    func walkedText() {
        let captured = talkTranscript + "\n\n" + talkSlides
        #expect(PaperWalkthroughSubject.walkedText(of: captured) == talkTranscript)
        #expect(PaperWalkthroughSubject.walkedText(of: talkTranscript) == talkTranscript)
        #expect(PaperWalkthroughSubject.walkedText(of: paperText) == paperText)
        #expect(PaperWalkthroughSubject.momentLimit(ofTranscript: talkTranscript) == 90 + 120)
        #expect(PaperWalkthroughSubject.momentLimit(ofTranscript: paperText) == nil)

        let sha = PaperContentPreparationService.sha256(talkTranscript)
        #expect(KnowledgeStore.walkthroughText(talkTranscript, matches: sha))
        #expect(KnowledgeStore.walkthroughText(captured, matches: sha), "capturing slides does not make the walk stale")
        #expect(!KnowledgeStore.walkthroughText(talkTranscript + " One more sentence.", matches: sha), "a changed transcript does")
        #expect(!KnowledgeStore.walkthroughText(talkTranscript, matches: nil))
        // A paper's walk is held to its whole text, as before.
        #expect(KnowledgeStore.walkthroughText(paperText, matches: PaperContentPreparationService.sha256(paperText)))
    }

    @Test("A video's step keeps its moment inside the talk; past the end, or on a source with no timeline, the moment is dropped and named")
    func momentValidation() throws {
        let steps = [
            PaperWalkthroughStep(id: "", kind: .explain, title: "Cristae", body: "Some words.", anchor: PaperWalkthroughAnchor(seconds: 50)),
            PaperWalkthroughStep(id: "", kind: .explain, title: "Later", body: "Some words.", anchor: PaperWalkthroughAnchor(seconds: 9000)),
        ]
        let onVideo = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "v", sourceSHA256: "sha", figures: [],
            allowsFigureAnchors: false, allowsMomentAnchors: true, momentLimit: 210,
            text: talkTranscript, author: .assistant
        )
        #expect(onVideo.walkthrough.steps[0].anchor?.seconds == 50)
        #expect(onVideo.walkthrough.steps[0].anchor?.momentClock == "0:50")
        #expect(onVideo.walkthrough.steps[1].anchor == nil)
        #expect(onVideo.warnings.contains { $0.contains("2:30:00") && $0.contains("past the end") })

        let onPaper = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: steps, sourceID: "p", sourceSHA256: "sha", figures: figures,
            text: paperText, author: .assistant
        )
        #expect(onPaper.walkthrough.steps.allSatisfy { $0.anchor == nil })
        #expect(onPaper.warnings.contains { $0.contains("0:50") && $0.contains("no timeline") })
    }

    @Test("A moment is stored as at and read back; an anchor written before moments reads with none")
    func momentCoding() throws {
        let anchor = PaperWalkthroughAnchor(passage: "Their curvature", seconds: 754)
        let data = try JSONEncoder().encode(anchor)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["at"] as? Int == 754)
        #expect(try JSONDecoder().decode(PaperWalkthroughAnchor.self, from: data) == anchor)
        let older = try JSONDecoder().decode(PaperWalkthroughAnchor.self, from: Data(#"{"passage":"x","page_number":3}"#.utf8))
        #expect(older.seconds == nil)
        #expect(!PaperWalkthroughAnchor(seconds: 0).isEmpty)
        #expect(PaperWalkthroughAnchor(seconds: 3723).momentClock == "1:02:03")
    }

    @Test("save_walkthrough on a video keeps each step's moment, places a quote where the talk says it, names a moment past the talk or unreadable, and get reads at back")
    func saveAndGet() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let talk = video()
        try store.knowledgeStore().saveSource(talk)

        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "The question", "body": "What cristae are.", "at": "0:05"],
            ["kind": "explain", "title": "Curvature", "body": "Why the folds matter.", "passage": "Their curvature concentrates the proton motive force along the ridge"],
            ["kind": "explain", "title": "Too late", "body": "Past the end.", "at": 5000],
            ["kind": "explain", "title": "Unreadable", "body": "A bad moment.", "at": "soon"],
            ["kind": "figure", "title": "A figure", "body": "No figures here.", "figure_label": "Figure 1", "at": 90],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": talk.id, "title": "Cristae walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "video")
        #expect(saved["moment_anchors"] as? Bool == true)
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect((saved["message"] as? String)?.contains("holds the video at its moment") == true)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("1:23:20") && $0.contains("past the end") })
        #expect(warnings.contains { $0.contains("soon") && $0.contains("no moment") })
        #expect(warnings.contains { $0.contains("Figure 1") && $0.contains("shown as text") })

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": talk.id]))
        #expect(got["status"] as? String == "ok", "a walk of the talk is current while the stored content carries its slides")
        #expect(got["moment_anchors"] as? Bool == true)
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        func at(_ index: Int) -> String? { (gotSteps[index]["anchor"] as? [String: Any])?["at"] as? String }
        #expect(at(0) == "0:05")
        // Quoted from the block under [0:42], a quarter of the way in: placed
        // inside that block, before the next one's [1:30].
        let placed = try #require(SourceImageReference.timestampSeconds(at(1)))
        #expect((42..<90).contains(placed))
        #expect(gotSteps[2]["anchor"] == nil)
        #expect(gotSteps[3]["anchor"] == nil)
        #expect(at(4) == "1:30")

        let stored = try #require(try await store.knowledgeStore().loadPaperWalkthrough(talk.id))
        #expect(stored.sourceSHA256 == PaperContentPreparationService.sha256(talkTranscript))
    }

    @Test("generate_walkthrough leaves a video to save_walkthrough, and get_walkthrough on a video with none says so")
    func writerRefusesVideos() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let talk = video()
        try store.knowledgeStore().saveSource(talk)
        do {
            _ = try await store.generateWalkthrough(arguments: ["source_id": talk.id])
            Issue.record("generate_walkthrough wrote a video's walk")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("save_walkthrough"))
        }
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": talk.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["subject"] as? String == "video")
        #expect((none["message"] as? String)?.contains("generate_walkthrough") == false)
    }
}

// MARK: - Animation walkthroughs

@Suite("Animation walkthrough storage")
struct AnimationWalkthroughStorageTests {

    private func animationWalk(for artifact: ArtifactRecord, title: String = "Two forces", subject: PaperWalkthrough.Subject = .animation, fingerprint: String? = nil) -> PaperWalkthrough {
        PaperWalkthrough(
            sourceID: artifact.id,
            sourceSHA256: fingerprint ?? PaperWalkthrough.animationFingerprint(linkedURL: artifact.linkedURL, artifactID: artifact.id),
            subject: subject,
            title: title,
            steps: [
                PaperWalkthroughStep(id: "step-1", kind: .explain, title: "One pump", body: "Two consequences.", animation: WalkthroughAnimationReference(animationID: artifact.id, step: 1)),
                PaperWalkthroughStep(id: "step-2", kind: .explain, title: "Nigericin", body: "Trades the pH term.", animation: WalkthroughAnimationReference(animationID: artifact.id, step: 5, conditions: ["iono": "nig"])),
            ],
            author: .assistant
        )
    }

    @Test("An animation's walkthrough saves on the artifact, reads back, queues the artifact for sync, replaces itself and deletes")
    func saveLoadDelete() async throws {
        let (storage, root) = makeTemporaryStorage("anim")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://pmf-two-components/")!, title: "One force, two components",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )

        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id) == false)
        #expect(try await storage.artifactIDsWithWalkthroughs().isEmpty)

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact))
        let loaded = try #require(try await storage.loadArtifactWalkthrough(artifact.id))
        #expect(loaded.title == "Two forces")
        #expect(loaded.subject == .animation)
        #expect(loaded.steps.count == 2)
        #expect(loaded.steps[1].animation?.conditions == ["iono": "nig"])
        #expect(try await storage.hasArtifactWalkthrough(artifact.id))
        #expect(try await storage.artifactIDsWithWalkthroughs() == [artifact.id])
        // The source table knows nothing of it.
        #expect(try await storage.loadPaperWalkthrough(artifact.id) == nil)

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, title: "Again"))
        #expect(try await storage.loadArtifactWalkthrough(artifact.id)?.title == "Again")

        #expect(try await storage.deleteArtifactWalkthrough(artifact.id))
        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.deleteArtifactWalkthrough(artifact.id) == false)
    }

    @Test("A source walk, a wrong fingerprint and a Site are refused; a re-addressed animation reads stale; deleting the animation takes the walk")
    func refusalsAndStaleness() async throws {
        let (storage, root) = makeTemporaryStorage("anim-stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://pmf-two-components/")!, title: "One force",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let site = try await storage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://a-site/")!, title: "A site",
            homeNotebookID: nil, linkedNotebookIDs: []
        )
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, subject: .source))
        }
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: artifact, fingerprint: "stale"))
        }
        await #expect(throws: (any Error).self) {
            try await storage.saveArtifactWalkthrough(animationWalk(for: site))
        }

        try await storage.saveArtifactWalkthrough(animationWalk(for: artifact))
        // Re-addressed under the walk: the walk's fingerprint no longer matches.
        let store = try KnowledgeStore(storeDirectory: root)
        var moved = try #require(try store.loadArtifact(artifact.id))
        moved.linkedURL = "foreverlm-site://pmf-renamed/"
        try store.saveArtifactRecord(moved)
        #expect(try await storage.loadArtifactWalkthrough(artifact.id) == nil)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id))

        try await storage.deleteArtifact(artifact.id)
        #expect(try await storage.hasArtifactWalkthrough(artifact.id) == false)
    }
}

@Suite("MCP walkthrough tools: animations")
struct MCPAnimationWalkthroughToolsTests {

    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_animation_walkthrough_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MCPError.invalidInput("Expected a JSON object, got: \(text.prefix(200))")
        }
        return object
    }

    private func seedArticle(_ store: MCPDataStore) throws -> StudioArticle {
        var article = StudioArticle(url: "https://example.com/post", title: "A post", sourceType: .article, discoveryOrigin: .manual)
        article.normalizedURL = URLNormalizer.normalize("https://example.com/post")
        article.domain = "example.com"
        article.content = paperText
        article.state = .ready
        try store.knowledgeStore().saveSource(article)
        return article
    }

    @Test("save_walkthrough with animation saves an animation walk keyed to the artifact, whose steps pin the page; get and delete read it back")
    func animationWalk() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://pmf-two-components/")!, title: "One force, two components",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "One pump", "body": "Two consequences.", "animation_step": 1, "passage": "Sleep pressure rises"],
            ["kind": "explain", "title": "Nigericin", "body": "Trades the pH term.", "animation_step": 5, "animation_conditions": ["iono": "nig", "resp": true]],
            ["kind": "quiz", "title": "Check", "body": "", "quiz": ["question": "Where did the force go?", "answer": "Into ΔpH.", "key_points": ["ΔpH"]]],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["animation": animation.id, "title": "Two forces", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "animation")
        #expect(saved["animation_id"] as? String == animation.id)
        #expect(saved["figure_anchors"] as? Bool == false)
        #expect(saved["animation_count"] as? Int == 2)
        let warnings = try #require(saved["warnings"] as? [String])
        #expect(warnings.count == 1 && warnings[0].contains("no page to point at"))
        #expect((saved["message"] as? String)?.contains("beside the animation") == true)

        let got = try parseJSON(try await store.getWalkthrough(arguments: ["animation": animation.id]))
        #expect(got["status"] as? String == "ok")
        #expect(got["subject"] as? String == "animation")
        #expect(got["animation_url"] as? String == "foreverlm-site://pmf-two-components/")
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        #expect(gotSteps.count == 3)
        #expect(gotSteps[0]["has_animation"] as? Bool == true)
        #expect(gotSteps[0]["anchor"] == nil)
        let second = try #require(gotSteps[1]["animation"] as? [String: Any])
        #expect(second["animation_id"] as? String == animation.id)
        #expect(second["step"] as? Int == 5)
        #expect(second["conditions"] as? [String: String] == ["iono": "nig", "resp": "1"])
        #expect(second["title"] as? String == "One force, two components")
        let url = try #require(second["url"] as? String)
        #expect(url.hasPrefix("foreverlm-site://pmf-two-components/?"))
        #expect(url.contains("embed=1") && url.contains("step=5") && url.contains("iono:nig"))
        #expect(gotSteps[2]["has_animation"] as? Bool == false)

        // list_animations says the animation is walked.
        let listed = try parseJSON(try await store.listAnimations(sourceID: nil))
        let entry = try #require((listed["animations"] as? [[String: Any]])?.first)
        #expect(entry["has_walkthrough"] as? Bool == true)

        let deleted = try parseJSON(try await store.deleteWalkthrough(arguments: ["animation": animation.id]))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("animation's walkthrough") == true)
        let none = try parseJSON(try await store.getWalkthrough(arguments: ["animation": animation.id]))
        #expect(none["status"] as? String == "none")
        #expect(none["subject"] as? String == "animation")
    }

    @Test("A source's step shows a saved animation by id; a Site, an unknown handle, both subjects at once and a stepless reference are refused")
    func referencesAndRefusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let article = try seedArticle(store)
        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://pmf-two-components/")!, title: "One force",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation
        )
        let site = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://a-site/")!, title: "A site",
            homeNotebookID: nil, linkedNotebookIDs: []
        )
        let steps: [[String: Any]] = [
            ["kind": "explain", "title": "Start", "body": "Read this first.", "passage": "Sleep pressure rises during waking"],
            ["kind": "explain", "title": "See it move", "body": "The force has two parts.", "animation": animation.id, "animation_step": 4],
        ]
        let saved = try parseJSON(try await store.saveWalkthrough(arguments: ["source_id": article.id, "title": "Walk", "steps": steps]))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["subject"] as? String == "article")
        #expect(saved["animation_count"] as? Int == 1)
        let got = try parseJSON(try await store.getWalkthrough(arguments: ["source_id": article.id]))
        let gotSteps = try #require(got["steps"] as? [[String: Any]])
        let ref = try #require(gotSteps[1]["animation"] as? [String: Any])
        #expect(ref["animation_id"] as? String == animation.id)
        #expect((ref["url"] as? String)?.contains("step=4") == true)
        #expect((gotSteps[0]["anchor"] as? [String: Any])?["passage"] as? String == "Sleep pressure rises during waking")

        for bad: [String: Any] in [
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation": site.id, "animation_step": 1]]],
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation": "nothing-here", "animation_step": 1]]],
            ["source_id": article.id, "title": "W", "steps": [["kind": "explain", "title": "S", "body": "B", "animation_step": 2]]],
            ["source_id": article.id, "animation": animation.id, "title": "W", "steps": steps],
            ["animation": site.id, "title": "W", "steps": steps],
        ] {
            await #expect(throws: MCPError.self) { try await store.saveWalkthrough(arguments: bad) }
        }
        await #expect(throws: MCPError.self) { try await store.generateWalkthrough(arguments: ["animation": animation.id]) }
    }
}
