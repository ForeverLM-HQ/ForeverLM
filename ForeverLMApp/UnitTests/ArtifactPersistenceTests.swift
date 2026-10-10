import Foundation
import SQLite3
import Testing
@testable import ForeverLM

@Suite("Global Artifact Persistence")
struct ArtifactPersistenceTests {
    @Test("A Doc attachment carries the document's headings, not its prose")
    func chatDocAttachmentOutline() {
        let markdown = """
        # The Landscape of Mitochondrial Therapeutics

        As long as energy flows well, you're good.

        ## Predicting lifespan

        NAD(P)H fluorescence.

        ```
        # not a heading, this is a shell comment
        ```

        #hashtag is prose, not a section

        ### Why are mitochondria important in aging?
        """

        let outline = ChatDocAttachment.outline(from: markdown)

        #expect(outline == [
            "The Landscape of Mitochondrial Therapeutics",
            "  Predicting lifespan",
            "    Why are mitochondria important in aging?",
        ])
    }

    @Test("A Doc outline stops at the heading limit")
    func chatDocAttachmentOutlineIsBounded() {
        let markdown = (1...(ChatDocAttachment.outlineHeadingLimit + 12))
            .map { "## Section \($0)" }
            .joined(separator: "\n\n")

        let outline = ChatDocAttachment.outline(from: markdown)

        #expect(outline.count == ChatDocAttachment.outlineHeadingLimit)
        #expect(outline.first == "  Section 1")
    }

    @Test("Artifact availability distinguishes iCloud downloads from missing files")
    func artifactICloudReadiness() {
        #expect(StorageService.artifactReadiness(
            fileExists: true,
            isDataless: false,
            isUbiquitousNotDownloaded: false,
            placeholderExists: false
        ) == .available)
        #expect(StorageService.artifactReadiness(
            fileExists: true,
            isDataless: false,
            isUbiquitousNotDownloaded: true,
            placeholderExists: false
        ) == .downloading)
        #expect(StorageService.artifactReadiness(
            fileExists: true,
            isDataless: true,
            isUbiquitousNotDownloaded: false,
            placeholderExists: false
        ) == .downloading)
        #expect(StorageService.artifactReadiness(
            fileExists: false,
            isDataless: false,
            isUbiquitousNotDownloaded: false,
            placeholderExists: true
        ) == .downloading)
        #expect(StorageService.artifactReadiness(
            fileExists: false,
            isDataless: false,
            isUbiquitousNotDownloaded: false,
            placeholderExists: false
        ) == .missing)
    }

    /// "Linked in" (docs/docs-design.md): the artifacts a source is linked to,
    /// grounded on it or citing it, derived from the records with no index.
    @Test("a source's linked artifacts are the ones grounded on it or citing it, book tokens expanding to chapters")
    func linkedArtifactsForSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedArtifactsTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        SourceArtifactCitationCache.shared.removeAll()

        func source(_ id: String, url: String, title: String, parentGroup: String? = nil) async throws {
            var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
            article.domain = URL(string: url)?.host ?? ""
            article.content = "Enough readable text for \(title) to count as a source."
            article.wordCount = 10
            article.state = .ready
            article.parentGroup = parentGroup
            try await storage.saveSource(article)
        }
        try await source("paper", url: "https://doi.org/10.1000/paper-1", title: "The paper")
        try await source("chapter", url: "https://example.com/book/ch3", title: "Chapter three", parentGroup: "book-group")
        try await source("other", url: "https://example.com/other", title: "Another source")

        // Grounded by the record's own links: an animation about the paper.
        let animation = try await storage.createLinkedArtifact(
            url: URL(string: "https://sites.foreverlm.com/anim/")!, title: "The animation",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation, sourceIDs: ["paper"]
        )
        // Grounded through a Doc's grounding link, and cited by its DOI.
        let groundedDoc = try await storage.createArtifact(
            title: "Grounded Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "A passage [standing on](foreverlm://grounding/paper) the paper."
        ).artifact
        let citingSnapshot = try await storage.createArtifact(
            title: "Citing Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "- [The paper](https://doi.org/10.1000/paper-1) — cited\n- [Not held](https://doi.org/10.1000/elsewhere) — not in this library"
        )
        let citingDoc = citingSnapshot.artifact
        // A Doc grounded on the book stands for its chapters too.
        let bookDoc = try await storage.createArtifact(
            title: "Book Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "[Notes](foreverlm://grounding/book:book-group) on the whole book."
        ).artifact
        // Unrelated: discusses the paper by name, links nothing.
        _ = try await storage.createArtifact(
            title: "Unrelated Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "The paper is mentioned here by title only."
        )

        let paperLinks = try await storage.artifactsLinked(toSource: "paper")
        let byID = Dictionary(uniqueKeysWithValues: paperLinks.map { ($0.artifact.id, $0.ways) })
        #expect(Set(byID.keys) == [animation.id, groundedDoc.id, citingDoc.id])
        #expect(byID[animation.id] == [.grounded])
        #expect(byID[groundedDoc.id] == [.grounded])
        #expect(byID[citingDoc.id] == [.cited])

        let chapterLinks = try await storage.artifactsLinked(toSource: "chapter")
        #expect(chapterLinks.map(\.artifact.id) == [bookDoc.id])
        #expect(chapterLinks.first?.ways == [.grounded])

        #expect(try await storage.artifactsLinked(toSource: "other").isEmpty)
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.artifactsLinked(toSource: "missing")
        }

        // The Doc's body is read once per revision: the cache answers the
        // second sweep, and a rewrite refreshes it.
        #expect(SourceArtifactCitationCache.shared.entry(for: citingDoc.id, updatedAt: citingDoc.updatedAt) != nil)
        let rewritten = try await storage.writeArtifactMarkdown(
            artifactID: citingDoc.id, markdown: "No links any more.", expectedRevision: citingSnapshot.revision
        ).artifact
        #expect(try await storage.artifactsLinked(toSource: "paper").map(\.artifact.id).contains(citingDoc.id) == false)
        #expect(SourceArtifactCitationCache.shared.entry(for: rewritten.id, updatedAt: rewritten.updatedAt)?.cited.isEmpty == true)
    }

    @Test("New and edited Articles enforce the body package text limit")
    func artifactWritesEnforceCloudSyncLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactSizeLimitTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let oversized = String(
            repeating: "x",
            count: ArtifactRecord.markdownByteLimit + 1
        )

        await #expect(throws: NotebookMarkdownFileError.self) {
            _ = try await storage.createArtifact(
                title: "Too large to sync",
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                markdown: oversized
            )
        }

        let created = try await storage.createArtifact(
            title: "Within the limit",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            markdown: "# Draft"
        )
        await #expect(throws: NotebookMarkdownFileError.self) {
            _ = try await storage.writeArtifactMarkdown(
                artifactID: created.artifact.id,
                markdown: oversized,
                expectedRevision: created.revision
            )
        }
    }

    @Test("Body package deterministically round-trips Markdown and referenced images")
    func artifactBodyPackageRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactBodyPackageTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        try image.write(to: root.appendingPathComponent("hero.png"))
        let markdown = "# Article\n\n![Hero](foreverlm://attachment/hero.png)"

        let first = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: root)
        let second = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: root)
        let decoded = try ArtifactBodyPackage.decode(first.data, expectedRevision: first.revision)

        #expect(first == second)
        #expect(decoded.markdown == markdown)
        #expect(decoded.attachments == [
            ArtifactBodyPackage.Attachment(token: "hero.png", mimeType: "image/png", data: image),
        ])
        #expect(throws: ArtifactBodyPackageError.self) {
            _ = try ArtifactBodyPackage.decode(first.data, expectedRevision: "wrong-revision")
        }
    }

    /// A ForeverLM site or animation kept in the library travels in the same
    /// body asset as its text copy (format 2). A Doc with no site is still
    /// format 1, byte for byte, so no Doc's revision moves.
    @Test("Body package format 2 carries a site's files, and a body with no site is format 1 as before")
    func artifactBodyPackageSiteFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactBodyPackageSiteTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("Content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)

        let plain = try ArtifactBodyPackage.encode(markdown: "Text copy", attachmentDirectory: nil)
        let plainAgain = try ArtifactBodyPackage.encode(markdown: "Text copy", attachmentDirectory: nil, siteFiles: nil)
        #expect(plain == plainAgain)
        #expect(String(decoding: plain.data, as: UTF8.self).contains("\"version\":1"))
        #expect(try ArtifactBodyPackage.decode(plain.data).siteFiles == nil)

        let files = [
            SiteFile(path: "index.html", data: Data("<h1>Atlas</h1>".utf8)),
            SiteFile(path: "css/site.css", data: Data("h1{}".utf8)),
            SiteFile(path: "flow.mp4", data: Data(repeating: 7, count: 32)),
        ]
        let site = try ArtifactBodyPackage.encode(markdown: "Atlas", attachmentDirectory: nil, siteFiles: files)
        let reordered = try ArtifactBodyPackage.encode(markdown: "Atlas", attachmentDirectory: nil, siteFiles: files.reversed())
        #expect(site == reordered, "the files are written in path order, so the revision is deterministic")
        let decoded = try ArtifactBodyPackage.decode(site.data, expectedRevision: site.revision)
        #expect(decoded.markdown == "Atlas")
        #expect(decoded.siteFiles?.map(\.path) == ["css/site.css", "flow.mp4", "index.html"])
        #expect(decoded.siteFiles?.first { $0.path == "flow.mp4" }?.data == Data(repeating: 7, count: 32))
        #expect(throws: ArtifactBodyPackageError.self) {
            _ = try ArtifactBodyPackage.encode(markdown: "x", attachmentDirectory: nil, siteFiles: [SiteFile(path: "../escape.html", data: Data())])
        }
        // A package cut short is refused whole.
        #expect(throws: (any Error).self) {
            _ = try ArtifactBodyPackage.decode(site.data.dropLast(4))
        }

        // Through the store: the files land under the record's Site folder
        // before the text copy, and go back out in the next package.
        let store = try KnowledgeStore(storeDirectory: root, contentDirectory: content)
        _ = try store.saveArtifactBodyPackageFromSync(site.data, artifactID: "site-a", expectedRevision: site.revision)
        #expect(store.hasLocalSite("site-a"))
        #expect(try store.localSiteFilePaths("site-a") == ["css/site.css", "flow.mp4", "index.html"])
        #expect(try store.readLocalSiteFile("site-a", path: "css/site.css") == Data("h1{}".utf8))
        #expect(FileManager.default.fileExists(atPath: content.appendingPathComponent("Artifacts/site-a/Site/index.html").path))
        let outbound = try #require(try store.loadArtifactBodyPackageForSync("site-a"))
        #expect(try ArtifactBodyPackage.decode(outbound.data).siteFiles?.count == 3)
        // A later body replaces the set whole; a Finder dotfile is not a file of the site.
        try Data().write(to: content.appendingPathComponent("Artifacts/site-a/Site/.DS_Store"))
        #expect(try store.localSiteFilePaths("site-a") == ["css/site.css", "flow.mp4", "index.html"])
        try store.writeLocalSiteFiles([SiteFile(path: "index.html", data: Data("<h1>Two</h1>".utf8))], artifactID: "site-a")
        #expect(try store.localSiteFilePaths("site-a") == ["index.html"])
        #expect(!store.hasLocalSite("doc-without-site"))
        #expect(try store.localSiteFiles("doc-without-site") == nil)
    }

    @Test("Comments keep their Article relationship and revision anchor through sync storage")
    func artifactCommentRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        let artifact = ArtifactRecord(
            id: "commented-article",
            title: "Commented Article",
            homeNotebookID: "notebook-a",
            linkedNotebookIDs: ["notebook-a"],
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        try store.saveArtifactRecord(artifact)
        let comment = ArtifactCommentRecord(
            id: "comment-a",
            artifactID: artifact.id,
            parentCommentID: nil,
            authorRecordName: "author-record",
            authorDisplayName: "Ada",
            body: "Clarify this claim.",
            anchorRevision: "revision-a",
            anchorStart: 4,
            anchorEnd: 18,
            anchorQuote: "this claim",
            createdAt: Date(timeIntervalSinceReferenceDate: 30),
            updatedAt: Date(timeIntervalSinceReferenceDate: 30),
            resolvedAt: nil
        )
        try store.saveArtifactCommentRecord(comment)

        #expect(try store.loadArtifactComments(artifact.id) == [comment])
        let pending = try store.pendingSyncChanges()
        #expect(pending.contains { $0.entity == .artifactComment && $0.logicalKey == comment.id })
        #expect(try store.loadArtifactCommentForSync(comment.id)?.artifactID == artifact.id)
    }

    // MARK: - Doc passages a chat was opened on

    @Test("A chat records the doc passage it started on, from both sides")
    func artifactChatLinkRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "mito-doc",
            title: "The Landscape of Mitochondrial Therapeutics",
            homeNotebookID: "notebook-a",
            linkedNotebookIDs: ["notebook-a"],
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        ))
        try store.createReviewSession(id: "chat-a", topic: "Mitochondrial peptides", sourceIDs: [])

        let link = try store.linkArtifactPassageToChat(
            artifactID: "mito-doc",
            sessionID: "chat-a",
            anchorRevision: "revision-a",
            anchorStart: 693,
            anchorEnd: 731,
            anchorQuote: "SS31 / elamipritide; does it really work",
            sectionTitle: "Mitochondrial peptides",
            createdAt: Date(timeIntervalSinceReferenceDate: 30)
        )

        #expect(try store.artifactChatLinks(artifactID: "mito-doc") == [link])
        #expect(try store.artifactChatLinks(sessionID: "chat-a") == [link])
        #expect(link.locatesPassage(inRevision: "revision-a"))
        // The doc has moved on: the quote survives, the offsets stop being an answer.
        #expect(!link.locatesPassage(inRevision: "revision-b"))
        // The link travels inside its session's record, so that is what must be queued.
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .reviewSession && $0.logicalKey == "chat-a"
        })
    }

    @Test("A link anchors the selection by offsets on its revision, and by quote once the doc moved on")
    func artifactChatLinkAnchorsSelection() {
        let link = ArtifactChatLinkRecord(
            id: "link-a",
            artifactID: "doc-a",
            sessionID: "chat-a",
            anchorRevision: "rev-1",
            anchorStart: 100,
            anchorEnd: 160,
            anchorQuote: "Mitochondria lose membrane potential\nlong before the cell dies.",
            sectionTitle: "Decline",
            createdAt: Date(timeIntervalSinceReferenceDate: 30)
        )

        // Same revision: the ranges only have to touch.
        #expect(link.anchors(selection: 150..<200, selectedText: "unrelated words", inRevision: "rev-1"))
        #expect(link.anchors(selection: 0..<101, selectedText: "unrelated words", inRevision: "rev-1"))
        // Same revision, elsewhere in the doc: the offsets are the answer, even
        // when the words happen to match.
        #expect(!link.anchors(selection: 160..<200, selectedText: link.anchorQuote, inRevision: "rev-1"))
        #expect(!link.anchors(selection: 0..<100, selectedText: link.anchorQuote, inRevision: "rev-1"))

        // The doc moved on: offsets mean nothing, the quote decides.
        let paragraph = "It is known that mitochondria lose membrane potential long before the cell dies. This is measurable."
        #expect(!link.anchors(selection: 100..<160, selectedText: "unrelated words", inRevision: "rev-2"))
        #expect(!link.anchors(selection: 100..<160, selectedText: "unrelated words", inRevision: ""))
        #expect(link.anchors(selection: 0..<10, selectedText: paragraph, inRevision: "rev-2"))
        #expect(link.anchors(selection: 0..<10, selectedText: "before the cell dies.", inRevision: ""))
        // A single common word inside the quote is not the passage.
        #expect(!link.anchors(selection: 0..<10, selectedText: "the", inRevision: "rev-2"))
        #expect(!link.anchors(selection: 0..<10, selectedText: "   ", inRevision: "rev-2"))
    }

    @Test("Asking twice about one passage keeps one link; a second passage adds one")
    func artifactChatLinkIsIdempotentPerAnchor() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-a",
            title: "Doc A",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])

        for _ in 0..<3 {
            try store.linkArtifactPassageToChat(
                artifactID: "doc-a",
                sessionID: "chat-a",
                anchorRevision: "rev-1",
                anchorStart: 10,
                anchorEnd: 24,
                anchorQuote: "MOTS-c",
                sectionTitle: "Peptides"
            )
        }
        #expect(try store.artifactChatLinks(artifactID: "doc-a").count == 1)

        try store.linkArtifactPassageToChat(
            artifactID: "doc-a",
            sessionID: "chat-a",
            anchorRevision: "rev-1",
            anchorStart: 40,
            anchorEnd: 51,
            anchorQuote: "Urolithin A",
            sectionTitle: "Peptides"
        )
        #expect(try store.artifactChatLinks(artifactID: "doc-a").count == 2)

        // A rewritten doc is a new anchor even over the same offsets.
        try store.linkArtifactPassageToChat(
            artifactID: "doc-a",
            sessionID: "chat-a",
            anchorRevision: "rev-2",
            anchorStart: 10,
            anchorEnd: 24,
            anchorQuote: "MOTS-c",
            sectionTitle: "Peptides"
        )
        #expect(try store.artifactChatLinks(artifactID: "doc-a").count == 3)
    }

    @Test("Deleting the doc or the chat takes its passage links with it")
    func artifactChatLinksAreSweptWithTheirEnds() throws {
        let store = try KnowledgeStore(inMemory: true)
        for id in ["doc-a", "doc-b"] {
            try store.saveArtifactRecord(ArtifactRecord(
                id: id,
                title: id,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                updatedAt: Date(timeIntervalSinceReferenceDate: 1)
            ))
        }
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])
        try store.createReviewSession(id: "chat-b", topic: "Chat B", sourceIDs: [])
        try store.linkArtifactPassageToChat(
            artifactID: "doc-a", sessionID: "chat-a", anchorRevision: "r",
            anchorStart: 0, anchorEnd: 5, anchorQuote: "alpha", sectionTitle: ""
        )
        try store.linkArtifactPassageToChat(
            artifactID: "doc-b", sessionID: "chat-b", anchorRevision: "r",
            anchorStart: 0, anchorEnd: 4, anchorQuote: "beta", sectionTitle: ""
        )

        // artifact_id carries no foreign key, so the doc's own delete has to sweep.
        try store.deleteArtifactRecord("doc-a")
        #expect(try store.artifactChatLinks(artifactID: "doc-a").isEmpty)
        #expect(try store.artifactChatLinks(artifactID: "doc-b").count == 1)

        try store.deleteReviewSession("chat-b")
        #expect(try store.artifactChatLinks(artifactID: "doc-b").isEmpty)
    }

    @Test("A message keeps the passage it was sent with, and a plain follow-up cannot blank it")
    func exchangeKeepsItsSelectionContext() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])
        let context = "Selected passage:\n> SS31 / elamipritide\n\nArticle ID: mito-doc"

        try store.recordPendingReviewUserMessage(
            sessionID: "chat-a",
            answer: "does it really work?",
            sourceRefs: [],
            contextContent: context
        )
        var exchanges = try store.loadReviewSessionExchanges(sessionID: "chat-a")
        #expect(exchanges.count == 1)
        #expect(exchanges.first?.contextContent == context)

        // The tutor answers, then the learner types a follow-up with no
        // selection of its own. That message is a new exchange and carries no
        // context; the first one must keep the passage it was asked about.
        try store.answerPendingReviewExchange(
            sessionID: "chat-a",
            answer: "does it really work?",
            evaluation: "Not impressively.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )
        try store.recordPendingReviewUserMessage(
            sessionID: "chat-a",
            answer: "and MOTS-c?",
            sourceRefs: []
        )
        exchanges = try store.loadReviewSessionExchanges(sessionID: "chat-a")
        #expect(exchanges.count == 2)
        #expect(exchanges.first?.contextContent == context)
        #expect(exchanges.last?.contextContent == nil)
    }

    @Test("Passage links and message context ride inside the chat's own CloudKit record")
    func artifactChatLinksRoundTripThroughSync() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-a",
            title: "Doc A",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])
        try store.recordPendingReviewUserMessage(
            sessionID: "chat-a",
            answer: "does it really work?",
            sourceRefs: [],
            contextContent: "Selected passage:\n> SS31"
        )
        try store.linkArtifactPassageToChat(
            artifactID: "doc-a", sessionID: "chat-a", anchorRevision: "rev-1",
            anchorStart: 693, anchorEnd: 731, anchorQuote: "SS31 / elamipritide",
            sectionTitle: "Mitochondrial peptides"
        )

        let outbound = try #require(try store.loadReviewSessionForSync("chat-a"))
        #expect(outbound.docLinks?.count == 1)
        #expect(outbound.docLinks?.first?.artifactID == "doc-a")
        #expect(outbound.docLinks?.first?.anchorQuote == "SS31 / elamipritide")
        #expect(outbound.exchanges.first?.contextContent == "Selected passage:\n> SS31")

        // The same payload decoded on the other Mac reproduces both.
        let encoded = try JSONEncoder().encode(outbound)
        let decoded = try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: encoded)
        let receiver = try KnowledgeStore(inMemory: true)
        try receiver.saveReviewSessionRecord(decoded)
        #expect(try receiver.artifactChatLinks(sessionID: "chat-a").first?.anchorQuote
            == "SS31 / elamipritide")
        #expect(try receiver.loadReviewSessionExchanges(sessionID: "chat-a").first?.contextContent
            == "Selected passage:\n> SS31")
    }

    @Test("A chat round-tripped through an older client keeps its passage links and context")
    func olderClientPayloadPreservesDocLinks() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])
        try store.recordPendingReviewUserMessage(
            sessionID: "chat-a",
            answer: "does it really work?",
            sourceRefs: [],
            contextContent: "Selected passage:\n> SS31"
        )
        try store.linkArtifactPassageToChat(
            artifactID: "doc-a", sessionID: "chat-a", anchorRevision: "rev-1",
            anchorStart: 0, anchorEnd: 4, anchorQuote: "SS31", sectionTitle: ""
        )

        let current = try #require(try store.loadReviewSessionForSync("chat-a"))
        // What a pre-v84 client sends back: no docLinks key at all, and a
        // transcript with the context stripped out of every message.
        let legacy = CloudKitReviewSessionPayload(
            id: current.id,
            topic: current.topic,
            startedAt: current.startedAt,
            endedAt: current.endedAt,
            status: current.status,
            overallScore: current.overallScore,
            summary: current.summary,
            sourceIDs: current.sourceIDs,
            cardIDs: current.cardIDs,
            exchangeCount: current.exchangeCount,
            exchanges: current.exchanges.map {
                CloudKitReviewExchangePayload(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    sequenceNumber: $0.sequenceNumber,
                    question: $0.question,
                    userAnswer: $0.userAnswer,
                    evaluation: $0.evaluation,
                    score: $0.score,
                    sourceRefs: $0.sourceRefs,
                    knowledgeNote: $0.knowledgeNote,
                    answeredAt: $0.answeredAt
                )
            }
        )
        #expect(legacy.docLinks == nil)

        try store.saveReviewSessionRecord(legacy)

        #expect(try store.artifactChatLinks(sessionID: "chat-a").count == 1)
        #expect(try store.loadReviewSessionExchanges(sessionID: "chat-a").first?.contextContent
            == "Selected passage:\n> SS31")
    }

    /// v84 is strictly additive: removing its table and its one column from a
    /// current schema reproduces the released v83 shape.
    private func makeVersion83Fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV83Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-a",
            title: "Doc A",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
        try store.createReviewSession(id: "chat-a", topic: "Chat A", sourceIDs: [])
        try store.recordPendingReviewUserMessage(
            sessionID: "chat-a",
            answer: "does it really work?",
            sourceRefs: []
        )
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("""
                DROP TABLE artifact_chat_links;
                ALTER TABLE review_exchanges DROP COLUMN context_content;
            """)
            try store.execForTesting("PRAGMA user_version = 83; COMMIT;")
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    @Test("One canonical artifact is editable from multiple Notebooks")
    func canonicalArtifactSpansNotebooks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactPersistenceTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let firstNotebook = try await makeNotebook(storage, title: "Cell biology")
        let secondNotebook = try await makeNotebook(storage, title: "Scientific writing")
        let created = try await storage.createArtifact(
            title: "Mitochondrial transfer",
            homeNotebookID: firstNotebook.id,
            linkedNotebookIDs: [firstNotebook.id, secondNotebook.id],
            markdown: "# Draft\n\nShared argument."
        )

        #expect(created.artifact.homeNotebookID == firstNotebook.id)
        #expect(Set(created.artifact.linkedNotebookIDs) == [firstNotebook.id, secondNotebook.id])
        #expect(try await storage.loadArtifacts(notebookID: firstNotebook.id).map(\.id) == [created.artifact.id])
        #expect(try await storage.loadArtifacts(notebookID: secondNotebook.id).map(\.id) == [created.artifact.id])

        let revised = try await storage.writeArtifactMarkdown(
            artifactID: created.artifact.id,
            markdown: "# Draft\n\nRevised from the writing Notebook.",
            expectedRevision: created.revision
        )
        #expect(revised.revision != created.revision)
        #expect(try await storage.notebookMaterialContext(notebookID: firstNotebook.id).contains("Revised from the writing Notebook."))
        #expect(try await storage.notebookMaterialContext(notebookID: secondNotebook.id).contains("Revised from the writing Notebook."))

        await #expect(throws: ArtifactError.self) {
            _ = try await storage.writeArtifactMarkdown(
                artifactID: created.artifact.id,
                markdown: "Stale overwrite",
                expectedRevision: created.revision
            )
        }

        _ = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: nil,
            homeNotebookID: nil,
            linkedNotebookIDs: [secondNotebook.id]
        )
        #expect(try await storage.loadArtifacts(notebookID: firstNotebook.id).isEmpty)
        #expect(try await storage.loadArtifacts(notebookID: secondNotebook.id).count == 1)

        let artifactURL = try await storage.artifactFileURL(created.artifact.id)
        #expect(artifactURL.path.contains("/Artifacts/\(created.artifact.id)/document.md"))
    }

    @Test("Deleting a home Notebook preserves the global artifact")
    func notebookDeletionPreservesArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactNotebookDeletionTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let home = try await makeNotebook(storage, title: "Home")
        let linked = try await makeNotebook(storage, title: "Linked")
        let created = try await storage.createArtifact(
            title: "Survivor",
            homeNotebookID: home.id,
            linkedNotebookIDs: [home.id, linked.id],
            markdown: "Still here."
        )

        try await storage.deleteLearningGoal(home.id, cascadeChildGoals: true)
        let artifact = try #require(try await storage.loadArtifacts().first)
        #expect(artifact.id == created.artifact.id)
        #expect(artifact.homeNotebookID == nil)
        #expect(artifact.linkedNotebookIDs == [linked.id])
        #expect(try await storage.artifactMarkdown(artifact.id).markdown == "Still here.")
    }

    @Test("Artifact metadata, Markdown, and all Notebook links round-trip through CloudKit")
    func artifactCloudKitRoundTrip() throws {
        let senderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactSyncSenderTests_\(UUID().uuidString)", isDirectory: true)
        let receiverRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactSyncReceiverTests_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: senderRoot)
            try? FileManager.default.removeItem(at: receiverRoot)
        }
        // Match production: SQLite and canonical content intentionally live in
        // different sibling directories. Using one test root for both masked a
        // path bug that omitted every Note body from CloudKit on real Macs.
        let senderStoreRoot = senderRoot.appendingPathComponent(".appdata", isDirectory: true)
        let senderContentRoot = senderRoot.appendingPathComponent("Content", isDirectory: true)
        let senderLegacyRoot = senderRoot.appendingPathComponent("LegacyCloud", isDirectory: true)
        let receiverStoreRoot = receiverRoot.appendingPathComponent(".appdata", isDirectory: true)
        let receiverContentRoot = receiverRoot.appendingPathComponent("Content", isDirectory: true)
        let sender = try KnowledgeStore(
            storeDirectory: senderStoreRoot,
            contentDirectory: senderContentRoot,
            legacyContentDirectories: [senderLegacyRoot]
        )
        let receiver = try KnowledgeStore(
            storeDirectory: receiverStoreRoot,
            contentDirectory: receiverContentRoot
        )
        let artifact = ArtifactRecord(
            id: "artifact-sync",
            title: "Cross-device article",
            homeNotebookID: "notebook-home",
            linkedNotebookIDs: ["notebook-a", "notebook-b"],
            isDraft: true,
            archivedAt: Date(timeIntervalSinceReferenceDate: 150),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try sender.saveArtifactRecord(artifact)
        let legacyDocument = senderLegacyRoot
            .appendingPathComponent("Artifacts/artifact-sync", isDirectory: true)
            .appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: legacyDocument.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# Cross-device article\n\nCites [[source]].".utf8)
            .write(to: legacyDocument, options: .atomic)
        #expect(!FileManager.default.fileExists(
            atPath: senderStoreRoot
                .appendingPathComponent("Artifacts/artifact-sync/document.md")
                .path
        ))
        let change = try #require(sender.pendingSyncChanges().first { $0.entity == .artifact })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        #expect(record.recordType == "Artifact")

        _ = try CloudKitRecordMapper.apply(record: record, to: receiver)
        #expect(try receiver.loadArtifact(artifact.id) == artifact)
        #expect(try receiver.loadArtifactMarkdownForSync(artifact.id) == "# Cross-device article\n\nCites [[source]].")
        let receiverRepair = try receiver.enqueueArtifactBodyRepairBatch(
            after: nil,
            limit: 10
        )
        #expect(receiverRepair.queuedCount == 0)

        let legacy = try JSONEncoder().encode(LegacyArtifactPayload(artifact: artifact))
        #expect(try JSONDecoder().decode(CloudKitArtifactPayload.self, from: legacy).markdown == nil)
    }

    @Test("Artifact payloads default old records to production")
    func legacyArtifactPayloadDefaultsToProduction() throws {
        let data = try JSONEncoder().encode(LegacyArtifactRecord(
            id: "legacy-production",
            title: "Already published",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        ))

        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: data)

        #expect(!decoded.isDraft)
        #expect(!decoded.isArchived)
        #expect(decoded.archivedAt == nil)
    }

    @Test("Archiving a doc keeps it whole and only marks it; restoring clears the mark")
    func archiveKeepsTheRecordWhole() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactArchiveTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let notebook = try await makeNotebook(storage, title: "Mitochondria")
        let created = try await storage.createArtifact(
            title: "MiTo — how lineage tracing works",
            homeNotebookID: notebook.id,
            linkedNotebookIDs: [notebook.id],
            markdown: "# MiTo\n\nA site's text."
        )
        #expect(!created.artifact.isArchived)

        let archived = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: nil,
            homeNotebookID: nil,
            linkedNotebookIDs: nil,
            isArchived: true
        )
        let archivedAt = try #require(archived.archivedAt)
        #expect(archived.isArchived)
        // Nothing else moved: title, links, home and body are as they were.
        #expect(archived.title == created.artifact.title)
        #expect(archived.homeNotebookID == notebook.id)
        #expect(archived.linkedNotebookIDs == [notebook.id])
        #expect(try await storage.loadArtifacts(notebookID: notebook.id).map(\.id) == [created.artifact.id])
        #expect(try await storage.artifactMarkdown(created.artifact.id).markdown == "# MiTo\n\nA site's text.")

        // Archiving again keeps the first date; the flag is idempotent.
        let again = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: nil,
            homeNotebookID: nil,
            linkedNotebookIDs: nil,
            isArchived: true
        )
        #expect(again.archivedAt == archivedAt)

        // An unrelated update leaves the archive alone.
        let renamed = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: "MiTo",
            homeNotebookID: nil,
            linkedNotebookIDs: nil
        )
        #expect(renamed.archivedAt == archivedAt)
        #expect(try await storage.loadArtifacts().first { $0.id == created.artifact.id }?.archivedAt == archivedAt)

        let restored = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: nil,
            homeNotebookID: nil,
            linkedNotebookIDs: nil,
            isArchived: false
        )
        #expect(!restored.isArchived)
        #expect(restored.archivedAt == nil)
        #expect(try await storage.loadArtifacts().first { $0.id == created.artifact.id }?.archivedAt == nil)
    }

    @Test("Hiding a doc follows the account: the record does not move, and the hide syncs as a record of its own")
    func hideFollowsTheAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactHideTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let notebook = try await makeNotebook(storage, title: "Mitochondria")
        let created = try await storage.createArtifact(
            title: "Mito company ideas",
            homeNotebookID: notebook.id,
            linkedNotebookIDs: [notebook.id],
            markdown: "# Ideas\n\nA doc's text."
        )
        #expect(!created.artifact.isHidden)
        let store = try await storage.notebookFilesKnowledgeStore()
        try store.clearAllPendingSyncChanges()

        let hidden = try await storage.setArtifactHidden(artifactID: created.artifact.id, isHidden: true)
        let hiddenAt = try #require(hidden.hiddenAt)
        #expect(hidden.isHidden)
        // Nothing about the record moved: not its date, not its archive, and
        // the Artifact itself was not queued — hiding is not a change to the
        // record. What was queued is the hide, as a record of its own, so the
        // learner's other Macs hide the same doc (product owner, 2026-09-13).
        #expect(hidden.updatedAt == created.artifact.updatedAt)
        #expect(!hidden.isArchived)
        #expect(hidden.title == created.artifact.title)
        #expect(hidden.linkedNotebookIDs == [notebook.id])
        let queued = try store.pendingSyncChanges()
        #expect(queued.map(\.entity) == [.hiddenArtifact])
        #expect(queued.first?.logicalKey == created.artifact.id)
        #expect(queued.first?.operation == .save)
        #expect(queued.first?.changedAt == hiddenAt)
        #expect(try store.loadHiddenArtifactForSync(created.artifact.id)?.hiddenAt == hiddenAt)
        #expect(try await storage.loadArtifacts().first { $0.id == created.artifact.id }?.hiddenAt == hiddenAt)
        #expect(try await storage.artifactMarkdown(created.artifact.id).markdown == "# Ideas\n\nA doc's text.")

        // The Artifact payload carries no trace of it: what a team member
        // decodes is a shown record.
        let encoded = try JSONEncoder().encode(hidden)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("hidden"))
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: encoded)
        #expect(!decoded.isHidden)
        #expect(decoded.hiddenAt == nil)

        // A re-save of the record — what an inbound sync or a team propagation
        // does — leaves the learner's choice standing, and moves the record's own
        // fields as it always did.
        var inbound = decoded
        inbound.title = "Mito company ideas (renamed elsewhere)"
        inbound.archivedAt = Date(timeIntervalSinceReferenceDate: 700)
        try store.saveArtifactRecord(inbound)
        let resaved = try #require(try store.loadArtifact(created.artifact.id))
        #expect(resaved.title == "Mito company ideas (renamed elsewhere)")
        #expect(resaved.archivedAt == Date(timeIntervalSinceReferenceDate: 700))
        #expect(resaved.hiddenAt == hiddenAt)

        // Hiding again keeps the first date and queues nothing new.
        try store.clearAllPendingSyncChanges()
        let again = try await storage.setArtifactHidden(artifactID: created.artifact.id, isHidden: true)
        #expect(again.hiddenAt == hiddenAt)
        #expect(try store.pendingSyncChanges().isEmpty)

        // An unrelated record update leaves the hide alone.
        let renamed = try await storage.updateArtifact(
            artifactID: created.artifact.id,
            title: "Mito company ideas",
            homeNotebookID: nil,
            linkedNotebookIDs: nil
        )
        #expect(renamed.hiddenAt == hiddenAt)
        #expect(try await storage.loadArtifacts().first { $0.id == created.artifact.id }?.hiddenAt == hiddenAt)

        // Showing it again tombstones the hide for the other Macs.
        try store.clearAllPendingSyncChanges()
        let shown = try await storage.setArtifactHidden(artifactID: created.artifact.id, isHidden: false)
        #expect(!shown.isHidden)
        #expect(shown.hiddenAt == nil)
        #expect(try await storage.loadArtifacts().first { $0.id == created.artifact.id }?.hiddenAt == nil)
        let tombstone = try #require(try store.pendingSyncChanges().first { $0.entity == .hiddenArtifact })
        #expect(tombstone.operation == .delete)
        #expect(tombstone.logicalKey == created.artifact.id)
    }

    @Test("A hide from another Mac lands whether or not its doc has arrived, and leaves with the doc")
    func hideFromAnotherMacLands() throws {
        let store = try KnowledgeStore(inMemory: true)
        let hiddenAt = Date(timeIntervalSinceReferenceDate: 1_000)
        // The hide arrives first: the row waits for its doc.
        try store.saveHiddenArtifactRecord(CloudKitHiddenArtifactPayload(artifactID: "doc-late", hiddenAt: hiddenAt))
        #expect(try store.loadArtifacts().isEmpty)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-late", title: "Late doc", homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(), updatedAt: Date()
        ))
        #expect(try store.loadArtifacts().first { $0.id == "doc-late" }?.hiddenAt == hiddenAt)
        // A republish keeps the hide's own date.
        #expect(try store.syncBackfillDate(for: .hiddenArtifact, logicalKey: "doc-late") == hiddenAt)
        // Shown on the other Mac: the row goes.
        try store.deleteHiddenArtifactRecord(artifactID: "doc-late")
        #expect(try store.loadArtifacts().first { $0.id == "doc-late" }?.hiddenAt == nil)
        // Deleting a hidden doc takes the hide with it, tombstone included.
        try store.saveHiddenArtifactRecord(CloudKitHiddenArtifactPayload(artifactID: "doc-late", hiddenAt: hiddenAt))
        try store.clearAllPendingSyncChanges()
        try store.deleteArtifactRecord("doc-late")
        #expect(try store.loadHiddenArtifactForSync("doc-late") == nil)
        let tombstones = try store.pendingSyncChanges().filter { $0.operation == .delete }.map(\.entity)
        #expect(Set(tombstones) == [.artifact, .hiddenArtifact])
    }

    @Test("A linked Google Doc keeps its URL through SQLite and the CloudKit payload, and refuses body writes")
    func linkedDocRoundTripAndReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedDocTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let url = try LinkedGoogleDoc.canonicalEditURL(
            from: "https://docs.google.com/document/d/1AbC/edit?usp=sharing"
        )

        let linked = try await storage.createLinkedArtifact(
            url: url,
            title: LinkedGoogleDoc.placeholderTitle,
            homeNotebookID: nil,
            linkedNotebookIDs: []
        )
        #expect(linked.isLinked)
        #expect(linked.linkedURL == "https://docs.google.com/document/d/1AbC/edit")
        let reloaded = try await storage.loadArtifacts()
        #expect(reloaded.first { $0.id == linked.id }?.linkedURL == linked.linkedURL)

        // The body starts as an explicit empty export, readable at once.
        let empty = try await storage.artifactMarkdown(linked.id)
        #expect(empty.markdown.isEmpty)
        #expect(empty.artifact.isLinked)

        // Nothing but the export refresh may write the body.
        await #expect(throws: ArtifactError.linkedDocReadOnly(LinkedGoogleDoc.placeholderTitle)) {
            _ = try await storage.writeArtifactMarkdown(
                artifactID: linked.id,
                markdown: "# Not allowed",
                expectedRevision: empty.revision
            )
        }
        let exported = try await storage.replaceLinkedArtifactExport(
            artifactID: linked.id,
            text: "Q3 planning\n\nShip the linked doc."
        )
        #expect(exported.markdown == "Q3 planning\n\nShip the linked doc.")
        #expect(exported.artifact.updatedAt > linked.updatedAt)
        // The same text again moves nothing, so an open that finds no change
        // queues no sync.
        let unchanged = try await storage.replaceLinkedArtifactExport(
            artifactID: linked.id,
            text: "Q3 planning\n\nShip the linked doc."
        )
        #expect(unchanged.artifact.updatedAt == exported.artifact.updatedAt)
        #expect(unchanged.revision == exported.revision)
        // A Markdown doc is not a linked doc; the export writer refuses it.
        let markdownDoc = try await storage.createArtifact(
            title: "Own words", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "# Mine"
        )
        await #expect(throws: (any Error).self) {
            _ = try await storage.replaceLinkedArtifactExport(artifactID: markdownDoc.artifact.id, text: "x")
        }

        // The URL is a key inside the artifact's encrypted JSON payload — the
        // same CloudKit field every artifact already syncs — and an older
        // payload without it decodes as a Markdown doc.
        let encoded = try JSONEncoder().encode(CloudKitArtifactPayload(artifact: exported.artifact))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let artifactJSON = try #require(json["artifact"] as? [String: Any])
        #expect(artifactJSON["linkedURL"] as? String == "https://docs.google.com/document/d/1AbC/edit")
        #expect(try JSONDecoder().decode(CloudKitArtifactPayload.self, from: encoded).artifact == exported.artifact)
        let legacy = try JSONEncoder().encode(LegacyArtifactRecord(
            id: "legacy", title: "Older", homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1), updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        ))
        #expect(try JSONDecoder().decode(ArtifactRecord.self, from: legacy).isLinked == false)
    }

    @Test("Converting a Markdown doc makes it a linked doc with its body kept; unlinking makes it editable again")
    func convertedDocLinksAndUnlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertDocTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let created = try await storage.createArtifact(
            title: "Q3 plan", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "# Q3 plan\n\nShip it."
        )
        let url = LinkedGoogleDoc.editURL(documentID: "1AbC")

        // The record changes kind in place: same id, same title, the URL added.
        let linked = try await storage.linkArtifactToGoogleDoc(artifactID: created.artifact.id, url: url)
        #expect(linked.id == created.artifact.id)
        #expect(linked.title == "Q3 plan")
        #expect(linked.isLinked)
        #expect(linked.linkedURL == "https://docs.google.com/document/d/1AbC/edit")
        #expect(linked.updatedAt >= created.artifact.updatedAt)
        #expect(try await storage.loadArtifacts().first { $0.id == linked.id }?.linkedURL == linked.linkedURL)

        // The Markdown that was sent to Google stays as the body until the
        // export replaces it, and is read-only from here on.
        let afterLink = try await storage.artifactMarkdown(created.artifact.id)
        #expect(afterLink.markdown == "# Q3 plan\n\nShip it.")
        #expect(afterLink.artifact.isLinked)
        await #expect(throws: ArtifactError.linkedDocReadOnly("Q3 plan")) {
            _ = try await storage.writeArtifactMarkdown(
                artifactID: created.artifact.id,
                markdown: "# Edited",
                expectedRevision: afterLink.revision
            )
        }

        // Once is enough: the doc cannot be linked a second time, and no other
        // doc may point at the same Google Doc.
        await #expect(throws: ArtifactError.alreadyLinked("Q3 plan")) {
            _ = try await storage.linkArtifactToGoogleDoc(
                artifactID: created.artifact.id,
                url: LinkedGoogleDoc.editURL(documentID: "2Other")
            )
        }
        let other = try await storage.createArtifact(
            title: "Other", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "Elsewhere."
        )
        await #expect(throws: ArtifactError.alreadyLinked("Q3 plan")) {
            _ = try await storage.linkArtifactToGoogleDoc(artifactID: other.artifact.id, url: url)
        }
        #expect(try await storage.loadArtifacts().first { $0.id == other.artifact.id }?.isLinked == false)
        await #expect(throws: ArtifactError.unavailable("missing")) {
            _ = try await storage.linkArtifactToGoogleDoc(artifactID: "missing", url: url)
        }

        // Unlinking gives back an editable Markdown doc holding the same text.
        let unlinked = try await storage.unlinkArtifact(artifactID: created.artifact.id)
        #expect(unlinked.id == created.artifact.id)
        #expect(!unlinked.isLinked)
        #expect(unlinked.linkedURL == nil)
        let afterUnlink = try await storage.artifactMarkdown(created.artifact.id)
        #expect(afterUnlink.markdown == "# Q3 plan\n\nShip it.")
        #expect(!afterUnlink.artifact.isLinked)
        let edited = try await storage.writeArtifactMarkdown(
            artifactID: created.artifact.id,
            markdown: "# Q3 plan\n\nShipped.",
            expectedRevision: afterUnlink.revision
        )
        #expect(edited.markdown == "# Q3 plan\n\nShipped.")
        // A doc that is not linked has nothing to unlink; the Google Doc it
        // was linked to may be linked again now.
        await #expect(throws: (any Error).self) {
            _ = try await storage.unlinkArtifact(artifactID: other.artifact.id)
        }
        let relinked = try await storage.linkArtifactToGoogleDoc(artifactID: other.artifact.id, url: url)
        #expect(relinked.linkedURL == "https://docs.google.com/document/d/1AbC/edit")
    }

    @Test("A linked doc's URL travels to another device inside the existing Artifact record")
    func linkedDocCloudKitRoundTrip() throws {
        let senderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedDocSyncSender_\(UUID().uuidString)", isDirectory: true)
        let receiverRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedDocSyncReceiver_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: senderRoot)
            try? FileManager.default.removeItem(at: receiverRoot)
        }
        let sender = try KnowledgeStore(
            storeDirectory: senderRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: senderRoot.appendingPathComponent("Content", isDirectory: true)
        )
        let receiver = try KnowledgeStore(
            storeDirectory: receiverRoot.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: receiverRoot.appendingPathComponent("Content", isDirectory: true)
        )
        let artifact = ArtifactRecord(
            id: "linked-sync",
            title: "Shared plan",
            homeNotebookID: nil,
            linkedNotebookIDs: ["notebook-a"],
            linkedURL: "https://docs.google.com/document/d/1AbC/edit",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try sender.saveArtifactRecord(artifact)
        try sender.saveArtifactMarkdownFromSync("Exported text.", artifactID: artifact.id)

        let change = try #require(sender.pendingSyncChanges().first { $0.entity == .artifact })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        #expect(record.recordType == "Artifact")
        _ = try CloudKitRecordMapper.apply(record: record, to: receiver)

        let received = try #require(try receiver.loadArtifact(artifact.id))
        #expect(received == artifact)
        #expect(received.isLinked)
        #expect(try receiver.loadArtifactMarkdownForSync(artifact.id) == "Exported text.")
    }

    @Test("Artifact body path repair is bounded and preserves newer edits")
    func artifactBodyPathRepairIsBoundedAndPreservesNewerEdits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactBodyRepairTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(
            storeDirectory: root.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: root.appendingPathComponent("Content", isDirectory: true)
        )

        for (id, updatedAt) in [
            ("artifact-a", Date(timeIntervalSinceReferenceDate: 100)),
            ("artifact-b", Date(timeIntervalSinceReferenceDate: 200)),
        ] {
            try store.saveArtifactRecord(ArtifactRecord(
                id: id,
                title: id,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                createdAt: updatedAt,
                updatedAt: updatedAt
            ))
            try store.saveArtifactMarkdownFromSync("# \(id)", artifactID: id)
            try store.clearPendingSyncChange(entity: .artifact, logicalKey: id)
        }

        let newerEdit = Date(timeIntervalSinceReferenceDate: 500)
        try store.markRecordChanged(
            entity: .artifact,
            logicalKey: "artifact-b",
            at: newerEdit
        )

        let first = try store.enqueueArtifactBodyRepairBatch(after: nil, limit: 1)
        let second = try store.enqueueArtifactBodyRepairBatch(
            after: first.lastScannedID,
            limit: 1
        )
        let pending = try store.pendingSyncChanges()
        let repaired = try #require(pending.first { $0.logicalKey == "artifact-a" })
        let edited = try #require(pending.first { $0.logicalKey == "artifact-b" })

        #expect(first.lastScannedID == "artifact-a")
        #expect(first.queuedCount == 1)
        #expect(!first.isComplete)
        #expect(second.lastScannedID == "artifact-b")
        #expect(second.queuedCount == 0)
        #expect(second.isComplete)
        #expect(repaired.changedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(edited.changedAt == newerEdit)
    }

    @Test("Artifact body repair adopts retired product links and queues the new body")
    func artifactBodyRepairAdoptsRetiredProductLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactBodyIdentityTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(
            storeDirectory: root.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: root.appendingPathComponent("Content", isDirectory: true)
        )
        let artifact = ArtifactRecord(
            id: "artifact-identity",
            title: "Identity",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.saveArtifactRecord(artifact)
        try store.saveArtifactMarkdownFromSync(
            "[Paper](feynmanlm://source/src_1) and prose feynmanlm://source/example",
            artifactID: artifact.id
        )
        try store.clearPendingSyncChange(entity: .artifact, logicalKey: artifact.id)

        let batch = try store.enqueueArtifactBodyRepairBatch(after: nil, limit: 10)

        #expect(batch.adoptedLinkCount == 1)
        #expect(batch.queuedCount == 1)
        #expect(try store.loadArtifactMarkdownForSync(artifact.id) ==
            "[Paper](foreverlm://source/src_1) and prose feynmanlm://source/example")
        #expect(try store.hasPendingSyncChange(entity: .artifact, logicalKey: artifact.id))
        let reloaded = try #require(try store.loadArtifact(artifact.id))
        #expect(reloaded.updatedAt > artifact.updatedAt)
    }

    @Test("Artifact body repair defers while a legacy iCloud placeholder downloads")
    func artifactBodyRepairDefersICloudPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactBodyPlaceholderTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = root.appendingPathComponent("LegacyCloud", isDirectory: true)
        let store = try KnowledgeStore(
            storeDirectory: root.appendingPathComponent(".appdata", isDirectory: true),
            contentDirectory: root.appendingPathComponent("Content", isDirectory: true),
            legacyContentDirectories: [legacyRoot]
        )
        let artifact = ArtifactRecord(
            id: "artifact-placeholder",
            title: "Downloading Note",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.saveArtifactRecord(artifact)
        try store.clearPendingSyncChange(entity: .artifact, logicalKey: artifact.id)
        let placeholder = legacyRoot
            .appendingPathComponent("Artifacts/artifact-placeholder", isDirectory: true)
            .appendingPathComponent(".document.md.icloud")
        try FileManager.default.createDirectory(
            at: placeholder.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("placeholder".utf8).write(to: placeholder)

        let batch = try store.enqueueArtifactBodyRepairBatch(after: nil, limit: 10)

        #expect(batch.queuedCount == 0)
        #expect(batch.deferredDownloadCount == 1)
        #expect(batch.isComplete)
        #expect(try !store.hasPendingSyncChange(entity: .artifact, logicalKey: artifact.id))
    }

    private struct LegacyArtifactPayload: Encodable {
        let artifact: ArtifactRecord
    }

    private struct LegacyArtifactRecord: Encodable {
        let id: String
        let title: String
        let homeNotebookID: String?
        let linkedNotebookIDs: [String]
        let createdAt: Date
        let updatedAt: Date
    }

    /// The released v105 Artifact shape (builds 90–93) differs from v106 by
    /// exactly one absent nullable column. Dropping it from a current store
    /// produces the historical table while preserving real relationship and
    /// sync tables.
    private func makeVersion105Fixture(
        articleCount: Int,
        conflictingArtifactIndex: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV105Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("DELETE FROM sync_changes; DELETE FROM sync_metadata;")
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifacts (
                    id, title, home_notebook_id, is_draft, created_at, updated_at
                )
                SELECT printf('article-%05d', n), printf('Article %05d', n),
                       'notebook-a', 0, n, n
                FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                SELECT printf('article-%05d', n), 'notebook-a', n FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO sync_changes (
                    entity_type, logical_key, record_name, operation, changed_at
                )
                SELECT 'artifact', printf('article-%05d', n),
                       printf('record-article-%05d', n), 'save', n FROM seq;
                INSERT INTO sync_metadata (
                    entity_type, logical_key, record_name, system_fields,
                    user_modification_at, is_deleted
                ) VALUES ('artifact', 'article-00001', 'record-article-00001', NULL, 1, 0);
                ALTER TABLE global_artifacts DROP COLUMN archived_at;
                DROP TABLE hidden_artifacts;
                DROP TABLE hidden_review_sessions;
            """)
            if conflictingArtifactIndex {
                try store.execForTesting("""
                    DROP INDEX idx_global_artifacts_updated;
                    CREATE TABLE idx_global_artifacts_updated (sentinel TEXT);
                """)
            }
            try store.execForTesting("PRAGMA user_version = 105; COMMIT;")
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    /// The shape build 101 wrote at schema 110: every artifact column of
    /// today's, and neither hide table (114). Rebuilding that shape from a
    /// current store produces the historical tables while preserving real
    /// relationship and sync tables.
    private func makeVersion110Fixture(
        articleCount: Int,
        conflictingArtifactIndex: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV110Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("DELETE FROM sync_changes; DELETE FROM sync_metadata;")
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifacts (
                    id, title, home_notebook_id, is_draft, created_at, updated_at, archived_at
                )
                SELECT printf('article-%05d', n), printf('Article %05d', n),
                       'notebook-a', 0, n, n, CASE WHEN n = 2 THEN 500 ELSE NULL END
                FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                SELECT printf('article-%05d', n), 'notebook-a', n FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO sync_changes (
                    entity_type, logical_key, record_name, operation, changed_at
                )
                SELECT 'artifact', printf('article-%05d', n),
                       printf('record-article-%05d', n), 'save', n FROM seq;
                INSERT INTO sync_metadata (
                    entity_type, logical_key, record_name, system_fields,
                    user_modification_at, is_deleted
                ) VALUES ('artifact', 'article-00001', 'record-article-00001', NULL, 1, 0);
                DROP TABLE hidden_artifacts;
                DROP TABLE hidden_review_sessions;
            """)
            if conflictingArtifactIndex {
                try store.execForTesting("""
                    DROP INDEX idx_global_artifacts_updated;
                    CREATE TABLE idx_global_artifacts_updated (sentinel TEXT);
                """)
            }
            try store.execForTesting("PRAGMA user_version = 110; COMMIT;")
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    /// The released v89 Artifact shape differs from v90 by exactly one absent
    /// nullable column. Rebuilding that table from a current store produces
    /// the historical table while preserving real relationship and sync tables.
    private func makeVersion89Fixture(
        articleCount: Int,
        conflictingArtifactIndex: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV89Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("DELETE FROM sync_changes; DELETE FROM sync_metadata;")
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifacts (
                    id, title, home_notebook_id, is_draft, created_at, updated_at
                )
                SELECT printf('article-%05d', n), printf('Article %05d', n),
                       'notebook-a', 0, n, n
                FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                SELECT printf('article-%05d', n), 'notebook-a', n FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO sync_changes (
                    entity_type, logical_key, record_name, operation, changed_at
                )
                SELECT 'artifact', printf('article-%05d', n),
                       printf('record-article-%05d', n), 'save', n FROM seq;
                INSERT INTO sync_metadata (
                    entity_type, logical_key, record_name, system_fields,
                    user_modification_at, is_deleted
                ) VALUES ('artifact', 'article-00001', 'record-article-00001', NULL, 1, 0);
                ALTER TABLE global_artifacts DROP COLUMN linked_url;
            """)
            if conflictingArtifactIndex {
                try store.execForTesting("""
                    DROP INDEX idx_global_artifacts_updated;
                    CREATE TABLE idx_global_artifacts_updated (sentinel TEXT);
                """)
            }
            try store.execForTesting("PRAGMA user_version = 89; COMMIT;")
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    /// The released v75 Artifact shape differs from v76 by exactly one absent
    /// metadata column. Rebuilding that table from a current store produces the
    /// historical table while preserving real relationship and sync tables.
    private func makeVersion75Fixture(
        articleCount: Int,
        conflictingArtifactIndex: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV75Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("DELETE FROM sync_changes; DELETE FROM sync_metadata;")
            try store.execForTesting("""
                INSERT INTO sources (id, date_added, state, source_type, status)
                VALUES
                    ('source-1', 1, 'ready', 'article', 'active'),
                    ('source-2', 2, 'ready', 'article', 'active');
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                VALUES
                    ('source-1', 'https://example.com/source-1', 'https://example.com/source-1', 'Source 1', 'example.com'),
                    ('source-2', 'https://example.com/source-2', 'https://example.com/source-2', 'Source 2', 'example.com');
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifacts (
                    id, title, home_notebook_id, is_draft, created_at, updated_at
                )
                SELECT printf('article-%05d', n), printf('Article %05d', n),
                       'notebook-a', 0, n, n
                FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                SELECT printf('article-%05d', n), 'notebook-a', n FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO sync_changes (
                    entity_type, logical_key, record_name, operation, changed_at
                )
                SELECT 'artifact', printf('article-%05d', n),
                       printf('record-article-%05d', n), 'save', n FROM seq;
                INSERT INTO sync_metadata (
                    entity_type, logical_key, record_name, system_fields,
                    user_modification_at, is_deleted
                ) VALUES ('artifact', 'article-00001', 'record-article-00001', NULL, 1, 0);
                ALTER TABLE global_artifacts DROP COLUMN is_draft;
            """)
            if conflictingArtifactIndex {
                try store.execForTesting("""
                    DROP INDEX idx_global_artifacts_updated;
                    CREATE TABLE idx_global_artifacts_updated (sentinel TEXT);
                """)
            }
            try store.execForTesting("PRAGMA user_version = 75; COMMIT;")
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    /// v71 is strictly additive. Removing its two new tables from a current
    /// schema produces the exact released v70 table/index shape; this is not a
    /// current-schema fixture with only a lowered version stamp.
    private func makeVersion70Fixture(articleCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactV70Fixture_\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("DELETE FROM sync_changes; DELETE FROM sync_metadata;")
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifacts (id, title, home_notebook_id, created_at, updated_at)
                SELECT printf('article-%05d', n), printf('Article %05d', n), 'notebook-a', n, n
                FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                SELECT printf('article-%05d', n), 'notebook-a', n FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(articleCount)
                )
                INSERT INTO sync_changes (
                    entity_type, logical_key, record_name, operation, changed_at
                )
                SELECT 'artifact', printf('article-%05d', n),
                       printf('record-article-%05d', n), 'save', n FROM seq;
                INSERT INTO sync_metadata (
                    entity_type, logical_key, record_name, system_fields,
                    user_modification_at, is_deleted
                ) VALUES ('artifact', 'article-00001', 'record-article-00001', NULL, 1, 0);
                DROP TABLE artifact_collaboration;
                DROP TABLE artifact_comments;
                PRAGMA user_version = 70;
                COMMIT;
            """)
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    private func sqliteScalar(_ database: OpaquePointer?, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// docs/memory-design.md, "Cards to check": a source's draft deck is the
    /// learner's own memory state, so it is never a Doc — no listing, notebook,
    /// link or team copy carries it — and a record an older build saved back
    /// as a Doc stays a deck by its id and is put back by the next drafts.
    @Test("A source's draft deck is private and never a Doc: no list, notebook, link or team copy carries it")
    func cardDecksStayPrivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardDeckPrivacyTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-deck")
        source.content = "Mitochondria couple respiration to ATP synthesis through a proton gradient."
        source.wordCount = 10
        source.state = .ready
        try await storage.saveSource(source)
        let notebook = try await makeNotebook(storage, title: "Mito notebook")
        let doc = try await storage.createArtifact(
            title: "Notes", homeNotebookID: notebook.id, linkedNotebookIDs: [notebook.id],
            markdown: "# Notes\n\nMy notes.", sourceIDs: ["src-deck"]
        ).artifact
        func card(_ front: String, quote: String) -> Flashcard {
            Flashcard.mint(
                front: front, back: "A proton gradient.", sourceID: "src-deck", sourceTitle: "Mitochondria",
                quote: quote, origin: .assistant, isRequested: false, at: Date()
            )
        }
        _ = try await storage.saveCardDrafts(
            [card("What couples respiration to ATP synthesis?", quote: "couple respiration to ATP synthesis")],
            sourceID: "src-deck", sourceTitle: "Mitochondria"
        )
        let store = try await storage.notebookFilesKnowledgeStore()
        let deckID = MemoryCard.draftDeckID(sourceID: "src-deck")
        let deck = try #require(try store.loadArtifact(deckID))
        #expect(deck.kind == .flashcards)
        #expect(deck.isCardDeck)
        #expect(deck.teamID == nil)
        #expect(deck.homeNotebookID == nil)
        #expect(deck.linkedNotebookIDs.isEmpty)
        #expect(deck.sourceIDs == ["src-deck"])
        #expect(!doc.isCardDeck)

        // No listing shows it: Docs, the Artifacts home, the notebook's
        // outputs and Docs, the source's Linked in, a notebook's chat context.
        #expect(try await storage.loadArtifacts().map(\.id) == [doc.id])
        #expect(try await storage.loadArtifacts(notebookID: notebook.id).map(\.id) == [doc.id])
        #expect(try await storage.myLibraryArtifacts().map(\.id) == [doc.id])
        #expect(try await storage.artifactsLinked(toSource: "src-deck").map(\.artifact.id) == [doc.id])
        #expect(try store.loadArtifacts(listing: .cardDecksOnly).map(\.id) == [deckID])
        #expect(try store.loadArtifacts(listing: .includingCardDecks).count == 2)
        #expect(!(try await storage.notebookArtifactContext(notebookID: notebook.id)).contains("Cards to check"))

        // Never in a team: the notebook shared with its Docs leaves the deck
        // behind, and sharing the deck itself is refused. The team is one this
        // account joined: under generation 2 sharing into a space it owns moves
        // the notebook (D21) and copies nothing, so a copy needs a joined team.
        let now = Date()
        let team = TeamRecord(
            id: "team-cards", name: "Nexus", role: .member, permission: .readWrite, zoneScope: .shared,
            zoneName: TeamRecord.zoneName(forTeamID: "team-cards"), zoneOwnerRecordName: "_owner-record", shareRecordName: nil,
            shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        )
        try store.saveTeam(team)
        _ = try await storage.shareNotebook(notebook.id, withTeam: team.id, includeSources: false, includeDocs: true, includeChats: false)
        #expect(try store.loadArtifact(TeamContentIdentity.artifactCopyID(teamID: team.id, original: doc)) != nil)
        #expect(try store.loadArtifact(TeamContentIdentity.artifactCopyID(teamID: team.id, original: deck)) == nil)
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.shareArtifact(deckID, withTeam: team.id)
        }

        // A build that does not know the kind saves the deck back as a Doc
        // filed under the notebook: its id still names it a deck, it stays out
        // of the notebook and the team, and the next drafts put it back.
        var asDoc = deck
        asDoc.kind = nil
        asDoc.homeNotebookID = notebook.id
        asDoc.linkedNotebookIDs = [notebook.id]
        try store.saveArtifactRecord(asDoc)
        #expect(try store.loadArtifact(deckID)?.isCardDeck == true)
        #expect(try await storage.loadArtifacts(notebookID: notebook.id).map(\.id) == [doc.id])
        #expect(try store.teamNotebooksAwaitingDoc(artifactID: deckID).isEmpty)
        _ = try await storage.saveCardDrafts(
            [card("Which gradient drives the synthase?", quote: "a proton gradient")],
            sourceID: "src-deck", sourceTitle: "Mitochondria"
        )
        let repaired = try #require(try store.loadArtifact(deckID))
        #expect(repaired.kind == .flashcards)
        #expect(repaired.homeNotebookID == nil)
        #expect(repaired.linkedNotebookIDs.isEmpty)
        #expect(try await storage.loadCardDrafts().first?.deck.cards.count == 2)
    }

    private func makeNotebook(_ storage: StorageService, title: String) async throws -> LearningGoalRecord {
        try await storage.createCompanionGoal(
            title: title,
            topic: title,
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
    }
}

@Suite("A Doc keeps its own pictures")
struct DocPictureTests {
    @Test("Picture lines are found by address, once each, outside code")
    func pictureLinesAreFound() {
        let markdown = """
        # Walk

        ![Slide 1](foreverlm://image/src_a/slide/1)

        ![Figure 3: The funnel](foreverlm://image/src_b/page/6?crop=0.1067,0.1236,0.7778,0.2247 "Caption")

        ![Slide 1 again](foreverlm://image/src_a/slide/1)

        [a link, not a picture](foreverlm://image/src_a/slide/2)

        ![Kept](foreverlm://attachment/0f1e2d3c.jpg)

        Inline code `![x](foreverlm://image/src_c/page/1)` is about the address.

        ```markdown
        ![y](foreverlm://image/src_d/page/1)
        ```
        """
        #expect(DocPictureLines.addresses(in: markdown) == [
            "foreverlm://image/src_a/slide/1",
            "foreverlm://image/src_b/page/6?crop=0.1067,0.1236,0.7778,0.2247",
        ])
    }

    @Test("Replacing an address keeps the line's description and caption, and leaves an unrendered line as written")
    func replacingKeepsTheLine() {
        let markdown = """
        ![Slide 1](foreverlm://image/src_a/slide/1)

        ![Figure 3](<foreverlm://image/src_b/page/6> "Caption")

        ![Missing](foreverlm://image/src_c/page/1)
        """
        let replaced = DocPictureLines.replacingAddresses(in: markdown) { address in
            switch address {
            case "foreverlm://image/src_a/slide/1": return "foreverlm://attachment/one.jpg"
            case "foreverlm://image/src_b/page/6": return "foreverlm://attachment/two.jpg"
            default: return nil
            }
        }
        #expect(replaced.kept == 2)
        #expect(replaced.markdown == """
        ![Slide 1](foreverlm://attachment/one.jpg)

        ![Figure 3](<foreverlm://attachment/two.jpg> "Caption")

        ![Missing](foreverlm://image/src_c/page/1)
        """)
    }

    @Test("A rendered picture becomes one of the doc's attachments, which the editor draws and the body package carries")
    func keptPictureIsAnAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocPictureTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let created = try await storage.createArtifact(title: "Walk", homeNotebookID: nil, linkedNotebookIDs: [])
        let id = created.artifact.id
        let markdown = "# Walk\n\n![Slide 1](foreverlm://image/src_a/slide/1)\n\n![Slide 1](foreverlm://image/src_a/slide/1)\n\n![Gone](foreverlm://image/src_gone/page/2)\n"
        let jpeg = SourceImageCatalog.RenderedImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), mediaType: "image/jpeg")

        let kept = try await storage.keepDocPictures(
            ["foreverlm://image/src_a/slide/1": jpeg],
            in: markdown,
            artifactID: id
        )

        #expect(kept.kept == 2)
        let tokens = try ArtifactBodyPackage.referencedAttachmentTokens(kept.markdown)
        let token = try #require(tokens.first)
        #expect(tokens.count == 1)
        #expect(token.hasSuffix(".jpeg") || token.hasSuffix(".jpg"))
        #expect(kept.markdown.contains("![Slide 1](foreverlm://attachment/\(token))"))
        #expect(kept.markdown.contains("![Gone](foreverlm://image/src_gone/page/2)"))
        let saved = try await storage.writeArtifactMarkdown(artifactID: id, markdown: kept.markdown, expectedRevision: created.revision)
        let urls = try await storage.artifactAttachmentDataURLs(id, markdown: saved.markdown)
        #expect(urls[token] == "data:image/jpeg;base64,\(jpeg.data.base64EncodedString())")
    }

    @Test("A picture this Mac cannot render is reported with its reason, not invented")
    func unrenderablePicturesAreReported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocPictureTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)

        let rendering = await storage.renderDocPictures(in: "![Figure](foreverlm://image/src_missing/page/1)\n")

        #expect(rendering.pictures.isEmpty)
        #expect(rendering.failures == [DocPictureFailure(
            address: "foreverlm://image/src_missing/page/1",
            reason: "no source src_missing is in this library"
        )])
    }
}

@Suite("A page keeps files attached for download")
struct DocFileAttachmentTests {
    private let token = "0f1e2d3c-4b5a-4968-8777-665544332211.pdf"

    @Test("A link to an attached file names its attachment exactly as a picture does")
    func linkLinesAreCollected() throws {
        let markdown = """
        # Report

        ![Figure](foreverlm://attachment/aaaaaaaa-0000-4000-8000-000000000001.png)

        [Quarterly numbers.pdf](foreverlm://attachment/\(token))

        Text with [the same file again](foreverlm://attachment/\(token)) and a [web link](https://example.com/x).

        [A file with a long name (final).xlsx](foreverlm://attachment/bbbbbbbb-0000-4000-8000-000000000002.xlsx)
        """
        let tokens = try ArtifactBodyPackage.referencedAttachmentTokens(markdown)

        #expect(tokens == [
            "aaaaaaaa-0000-4000-8000-000000000001.png",
            token,
            "bbbbbbbb-0000-4000-8000-000000000002.xlsx",
        ], "a plain link keeps its file, once, in the order the page names it")
        #expect(try ArtifactBodyPackage.referencedAttachmentTokens("[a](foreverlm://attachment/\(token))") == [token])
        #expect(try ArtifactBodyPackage.referencedAttachmentTokens("[a](https://example.com/x)").isEmpty)
        // A link that tries to leave the attachments folder is refused whole.
        #expect(throws: ArtifactBodyPackageError.self) {
            _ = try ArtifactBodyPackage.referencedAttachmentTokens("[a](foreverlm://attachment/../document.md)")
        }
    }

    @Test("A page's body package carries a file named by a plain link, and decodes it back")
    func packageCarriesLinkedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocFileAttachmentTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x25, count: 4_096)
        try bytes.write(to: root.appendingPathComponent(token))
        let markdown = "# Report\n\n[Quarterly numbers.pdf](foreverlm://attachment/\(token))\n"

        let encoded = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: root)
        let decoded = try ArtifactBodyPackage.decode(encoded.data, expectedRevision: encoded.revision)

        #expect(decoded.markdown == markdown)
        #expect(decoded.attachments.map(\.token) == [token])
        #expect(decoded.attachments.first?.data == bytes)
        #expect(decoded.attachments.first?.mimeType == "application/pdf")
        // A link whose file is missing is an error, not a silently dropped file.
        let empty = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: empty)
        }
    }

    @Test("Stored tokens are a UUID and an extension, and nothing else names a file")
    func tokenShape() {
        #expect(ArtifactFileAttachment.isStoredToken(token))
        #expect(ArtifactFileAttachment.isStoredToken("0F1E2D3C-4B5A-4968-8777-665544332211.bin"))
        for bad in [
            "", "hero.png", "../document.md", "0f1e2d3c-4b5a-4968-8777-665544332211", "0f1e2d3c-4b5a-4968-8777-665544332211.",
            "0f1e2d3c-4b5a-4968-8777-665544332211.p/df", "0f1e2d3c-4b5a-4968-8777-665544332211..pdf",
            "x/0f1e2d3c-4b5a-4968-8777-665544332211.pdf", "0f1e2d3c-4b5a-4968-8777-665544332211.pdf/",
            "0f1e2d3c-4b5a-4968-8777-665544332211.pdf\n", "0f1e2d3c-4b5a-4968-8777-665544332211.averyveryveryverylongextension",
        ] {
            #expect(!ArtifactFileAttachment.isStoredToken(bad), "\(bad.debugDescription)")
        }
    }

    @Test("A file's extension is lowercased and cleaned for its token, and bin when none is left")
    func extensionIsSanitized() {
        #expect(ArtifactFileAttachment.sanitizedExtension("PDF") == "pdf")
        #expect(ArtifactFileAttachment.sanitizedExtension("tar.gz") == "targz")
        #expect(ArtifactFileAttachment.sanitizedExtension("") == "bin")
        #expect(ArtifactFileAttachment.sanitizedExtension("../é ") == "bin")
        #expect(ArtifactFileAttachment.sanitizedExtension(String(repeating: "a", count: 40)).count == 16)
        #expect(ArtifactFileAttachment.isStoredToken("0f1e2d3c-4b5a-4968-8777-665544332211." + ArtifactFileAttachment.sanitizedExtension("Weird Ext!")))
    }

    @Test("Save file… offers the link's name, or the page's title and the token's extension when the link has none")
    func suggestedNames() {
        #expect(ArtifactFileAttachment.suggestedFileName(linkName: "Quarterly numbers.pdf", token: token, pageTitle: "Report") == "Quarterly numbers.pdf")
        #expect(ArtifactFileAttachment.suggestedFileName(linkName: "a/b: c.pdf", token: token, pageTitle: "Report") == "a-b- c.pdf")
        #expect(ArtifactFileAttachment.suggestedFileName(linkName: token, token: token, pageTitle: "Q3 / Report") == "Q3 - Report.pdf")
        #expect(ArtifactFileAttachment.suggestedFileName(linkName: "  ", token: token, pageTitle: "Report") == "Report.pdf")
        #expect(ArtifactFileAttachment.suggestedFileName(linkName: "", token: token, pageTitle: "") == "Attachment.pdf")
    }

    @Test("Attaching keeps the file's bytes under a token the page links, refuses what a page cannot hold, and hands the file back only for its own tokens")
    func importKeepsRefusesAndResolves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocFileImportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root.appendingPathComponent("store", isDirectory: true))
        let page = try await storage.createArtifact(title: "Report", homeNotebookID: nil, linkedNotebookIDs: []).artifact

        // Any kind of file, its extension lowercased.
        let bytes = Data((0..<2_048).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("Quarterly Numbers.PDF")
        try bytes.write(to: source)
        let kept = try await storage.importArtifactFile(source, artifactID: page.id)
        #expect(kept.name == "Quarterly Numbers.PDF")
        #expect(kept.size == bytes.count)
        #expect(kept.token.hasSuffix(".pdf"))
        #expect(ArtifactFileAttachment.isStoredToken(kept.token))
        let stored = try await storage.artifactAttachmentFileURL(artifactID: page.id, token: kept.token)
        #expect(try Data(contentsOf: stored) == bytes)

        // No extension: bin.
        let bare = root.appendingPathComponent("LICENSE")
        try Data("terms".utf8).write(to: bare)
        #expect(try await storage.importArtifactFile(bare, artifactID: page.id).token.hasSuffix(".bin"))

        // Over 25 MB: refused before the file is read, and nothing is stored.
        let big = root.appendingPathComponent("big.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ArtifactFileAttachment.maxBytes + 1))
        try handle.close()
        await #expect(throws: ArtifactError.fileTooLarge(maxMegabytes: 25)) {
            _ = try await storage.importArtifactFile(big, artifactID: page.id)
        }
        // Empty, and a folder: refused with a reason.
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        await #expect(throws: KnowledgeStoreError.self) { _ = try await storage.importArtifactFile(empty, artifactID: page.id) }
        await #expect(throws: KnowledgeStoreError.self) { _ = try await storage.importArtifactFile(root, artifactID: page.id) }

        // Only a token this app wrote resolves, and only inside the page's own folder.
        for bad in ["../document.md", "hero.png", kept.token + "/..", "0f1e2d3c-4b5a-4968-8777-665544332211.pdf"] {
            await #expect(throws: (any Error).self) {
                _ = try await storage.artifactAttachmentFileURL(artifactID: page.id, token: bad)
            }
        }
    }

    @Test("A linked page (a Google Doc) takes no file, as it takes no picture")
    func linkedPageRefusesFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocFileLinkedTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root.appendingPathComponent("store", isDirectory: true))
        let linked = try await storage.createLinkedArtifact(
            url: URL(string: "https://docs.google.com/document/d/abc123/edit")!,
            title: "Shared plan", homeNotebookID: nil, linkedNotebookIDs: []
        )
        let source = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)

        await #expect(throws: ArtifactError.linkedDocReadOnly("Shared plan")) {
            _ = try await storage.importArtifactFile(source, artifactID: linked.id)
        }
    }
}
